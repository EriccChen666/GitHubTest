#!/bin/bash
# tcp_monitor.sh — 持续对「服务映射」目标做 TCP 端口探测并记录中断时间段
#
# 适用场景：
#   - VPC 私有网络服务映射   (kind=vpc)
#   - 物理网络服务映射       (kind=underlay)
#   两类映射健康与否，均以「映射后的服务端口 IP:PORT 是否可建立 TCP 连接」为判据。
#
# 用法：
#   ./tcp_monitor.sh -k <vpc|underlay> -t <目的地址> -p <端口> [options]
#
# 示例：
#   ./tcp_monitor.sh -k vpc      -t 10.0.0.23   -p 3306
#   ./tcp_monitor.sh -k underlay -t 172.16.5.8  -p 8080 -S 10.0.0.5     # 指定源 IP
#   ./tcp_monitor.sh -k vpc      -t 2400:da00::1 -p 443  -6             # IPv6
#
# 行为（与 DC 的 ping_monitor.sh 保持一致的风格）：
#   - 每 INTERVAL 秒做一次 TCP 连接探测（默认 1s）
#   - 启动时打印环境信息（hostname/kernel/探测方式/解析IP/路由/出接口/MTU）
#   - 每次探测失败都会打一行 FAIL（含失败原因）
#   - 每 60s 输出一次 SUMMARY（sent/lost/loss%/connect耗时 min/avg/max）
#   - 连续 THRESHOLD 次失败视为"中断开始"，下次成功视为"中断结束"
#   - 每日全量日志：LOG_DIR/tcp_<kind>_<user>_<target>_<port>_YYYYMMDD.log
#   - 中断事件单独写入：LOG_DIR/outage_<kind>_<user>_<target>_<port>.log，便于审计
#
# 探测实现优先级：nc(netcat) > /dev/tcp(bash 内建) > python3 socket
# （不依赖对端有 ICMP/ping，只看 TCP 三次握手是否成功）

set -u
# cron 启动时 PATH 只有 /usr/bin:/bin，ip/ss 等在 sbin 下会找不到，导致环境信息缺失
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin"

KIND=""                  # vpc | underlay
TARGET=""
PORT=""
FORCE_V6=0
LOG_DIR="/var/log/tcp_monitor"
INTERVAL=1               # 秒
THRESHOLD=3              # 连续 3 次失败判定为中断
CONNECT_TIMEOUT=2        # 单次 TCP 连接超时秒数
SOURCE_IP=""             # 可选：指定探测源地址

usage() {
    cat <<EOF
Usage: $0 -k <vpc|underlay> -t <target> -p <port> [options]
  -k <kind>       映射类型：vpc（VPC私有网络服务映射）| underlay（物理网络服务映射），必填
  -t <target>     目的地址（IPv4/IPv6 或 域名），必填
  -p <port>       目的 TCP 端口，必填
  -6              强制按 IPv6 处理（不指定则按地址自动判断）
  -d <dir>        日志目录，默认 /var/log/tcp_monitor
  -i <interval>   探测间隔秒数，默认 1
  -T <threshold>  连续多少次失败判为中断，默认 3
  -w <timeout>    单次 TCP 连接超时秒数，默认 2
  -S <src-ip>     可选：指定探测源 IP
  -h              显示帮助
EOF
    exit 1
}

while getopts "k:t:p:6d:i:T:w:S:h" opt; do
    case "$opt" in
        k) KIND="$OPTARG" ;;
        t) TARGET="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        6) FORCE_V6=1 ;;
        d) LOG_DIR="$OPTARG" ;;
        i) INTERVAL="$OPTARG" ;;
        T) THRESHOLD="$OPTARG" ;;
        w) CONNECT_TIMEOUT="$OPTARG" ;;
        S) SOURCE_IP="$OPTARG" ;;
        h|*) usage ;;
    esac
done

[ -z "$KIND" ] && usage
[ -z "$TARGET" ] && usage
[ -z "$PORT" ] && usage

# 规范化 / 校验 kind
case "$KIND" in
    vpc|VPC)           KIND="vpc" ;;
    underlay|UNDERLAY|phy|physical) KIND="underlay" ;;
    *) echo "ERR: -k 只能是 vpc 或 underlay"; exit 1 ;;
esac

# 校验端口
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    echo "ERR: -p 端口非法：$PORT"; exit 1
fi

# ----- 自动判断 v4/v6 -----
IS_V6=0
if [ "$FORCE_V6" -eq 1 ] || [[ "$TARGET" == *:* ]]; then
    IS_V6=1
fi

# ----- 选择 TCP 探测方式 -----
# PROBE_METHOD: nc | devtcp | python3
PROBE_METHOD=""
NC_SUPPORTS_W=0
if command -v nc >/dev/null 2>&1; then
    PROBE_METHOD="nc"
    # 检测 nc 是否支持 -w 超时（绝大多数发行版支持）
    if nc -h 2>&1 | grep -q -- '-w'; then
        NC_SUPPORTS_W=1
    fi
elif command -v python3 >/dev/null 2>&1; then
    PROBE_METHOD="python3"
else
    # bash /dev/tcp 内建（注意：IPv6 与指定源 IP 时 /dev/tcp 能力有限）
    PROBE_METHOD="devtcp"
fi

# ----- 硬超时兜底能力检测 -----
# 关键：故障有"黑洞/丢包"形态（SYN 无响应），若探测命令自身超时不生效，
# 会把整个监控循环夯死。因此无论哪种探测方式，都用外部 timeout 再包一层兜底，
# 确保"任何一次探测"都有时间上界，脚本永不夯住。
HAVE_TIMEOUT=0
TIMEOUT_BIN=""
if command -v timeout >/dev/null 2>&1; then
    HAVE_TIMEOUT=1; TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then
    # macOS (coreutils) 下为 gtimeout
    HAVE_TIMEOUT=1; TIMEOUT_BIN="gtimeout"
fi
# 兜底硬超时 = 连接超时 + 2s 缓冲（给进程清理留余量）
HARD_TIMEOUT=$(( CONNECT_TIMEOUT + 2 ))

# ----- 准备日志目录与文件 -----
mkdir -p "$LOG_DIR" 2>/dev/null || true
# 文件名带上 "类型 + 用户名 + 目标地址 + 端口 + 源地址(可选)"，避免互相覆盖
RUN_USER="$(id -un 2>/dev/null || whoami)"
SAFE_TARGET=$(echo "$TARGET" | tr ':/' '__')
if [ -n "$SOURCE_IP" ]; then
    SAFE_SRC=$(echo "$SOURCE_IP" | tr ':/' '__')
    FILE_TAG="${KIND}_${RUN_USER}_${SAFE_TARGET}_${PORT}_from_${SAFE_SRC}"
else
    FILE_TAG="${KIND}_${RUN_USER}_${SAFE_TARGET}_${PORT}"
fi
OUTAGE_LOG="$LOG_DIR/outage_${FILE_TAG}.log"
PIDFILE="$LOG_DIR/.tcp_${FILE_TAG}.pid"

# ----- 单实例保护：防止 crontab 重复拉起 -----
# 不能只看 kill -0：设备重启后 pidfile 里的旧 PID 可能被别的进程复用，
# 那样脚本会误判"已在运行"而永远起不来。所以还要核对该 PID 确实是本脚本且参数相同。
pid_is_self() {
    local p="$1" cmd
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null || return 1
    [ -r "/proc/$p/cmdline" ] || return 0   # 无 /proc 的系统退回旧逻辑
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in
        *tcp_monitor.sh*"-t $TARGET"*"-p $PORT"*) return 0 ;;
        *) return 1 ;;
    esac
}
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
    if pid_is_self "$OLD_PID"; then
        exit 0
    fi
fi
echo $$ > "$PIDFILE"

cleanup() {
    rm -f "$PIDFILE"
    exit 0
}
trap cleanup INT TERM EXIT

ts() { date '+%Y-%m-%d %H:%M:%S'; }

today_log() {
    echo "$LOG_DIR/tcp_${FILE_TAG}_$(date '+%Y%m%d').log"
}

# 日志目录自愈：故障期间若目录被外部删除/挂载异常恢复，确保能继续写，不丢日志。
ensure_log_dir() {
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null || true
}

# 写日志：所有写入都加 2>/dev/null，保证即使磁盘满/目录丢失也绝不让脚本因写日志失败而退出或报错中断循环。
log() {
    ensure_log_dir
    echo "[$(ts)] $*" >> "$(today_log)" 2>/dev/null || true
}

log_outage() {
    ensure_log_dir
    echo "[$(ts)] $*" >> "$OUTAGE_LOG" 2>/dev/null || true
}

# ===== 启动时打环境信息 =====
KIND_DESC=$([ "$KIND" = "vpc" ] && echo "VPC私有网络服务映射" || echo "物理网络服务映射")
log "========== tcp_monitor START kind=$KIND($KIND_DESC) user=$RUN_USER target=$TARGET port=$PORT src=${SOURCE_IP:-auto} method=$PROBE_METHOD interval=${INTERVAL}s threshold=$THRESHOLD timeout=${CONNECT_TIMEOUT}s =========="
{
    echo "[$(ts)] ENV host=$(hostname 2>/dev/null) kernel=$(uname -r 2>/dev/null) os=$(uname -s 2>/dev/null)"
    echo "[$(ts)] ENV probe_method=$PROBE_METHOD nc_supports_w=$NC_SUPPORTS_W is_v6=$IS_V6"
    echo "[$(ts)] ENV have_timeout=$HAVE_TIMEOUT timeout_bin=${TIMEOUT_BIN:-none} hard_timeout=${HARD_TIMEOUT}s connect_timeout=${CONNECT_TIMEOUT}s (防夯住兜底)"
    if [ "$HAVE_TIMEOUT" -eq 0 ] && [ "$PROBE_METHOD" = "nc" ] && [ "$NC_SUPPORTS_W" -eq 0 ]; then
        echo "[$(ts)] ENV WARN 系统无 timeout 命令且 nc 不支持 -w，黑洞场景下探测可能偏慢，建议安装 coreutils(timeout)"
    fi
    # 解析目标 IP（域名时给出实际 IP）
    if command -v getent >/dev/null 2>&1; then
        if [ "$IS_V6" -eq 1 ]; then
            RESOLVED=$(getent ahostsv6 "$TARGET" 2>/dev/null | awk '{print $1; exit}')
        else
            RESOLVED=$(getent ahostsv4 "$TARGET" 2>/dev/null | awk '{print $1; exit}')
        fi
    else
        RESOLVED=$(getent hosts "$TARGET" 2>/dev/null | awk '{print $1; exit}')
    fi
    echo "[$(ts)] ENV target=$TARGET port=$PORT resolved_ip=${RESOLVED:-N/A} source_ip=${SOURCE_IP:-auto}"
    # 路由 + 出接口（v4/v6 分别处理）
    if [ "$IS_V6" -eq 1 ]; then
        if [ -n "$SOURCE_IP" ]; then
            ROUTE_INFO=$(ip -6 route get "${RESOLVED:-$TARGET}" from "$SOURCE_IP" 2>/dev/null | head -1)
        else
            ROUTE_INFO=$(ip -6 route get "${RESOLVED:-$TARGET}" 2>/dev/null | head -1)
        fi
    else
        if [ -n "$SOURCE_IP" ]; then
            ROUTE_INFO=$(ip -4 route get "${RESOLVED:-$TARGET}" from "$SOURCE_IP" 2>/dev/null | head -1)
        else
            ROUTE_INFO=$(ip -4 route get "${RESOLVED:-$TARGET}" 2>/dev/null | head -1)
        fi
    fi
    echo "[$(ts)] ENV route=${ROUTE_INFO:-N/A}"
    # 出接口 MTU
    DEV=$(echo "$ROUTE_INFO" | sed -n 's/.* dev \([^ ]*\).*/\1/p')
    if [ -n "$DEV" ]; then
        MTU=$(cat "/sys/class/net/$DEV/mtu" 2>/dev/null)
        echo "[$(ts)] ENV out_dev=$DEV mtu=${MTU:-N/A}"
    fi
    # 若指定了源 IP，校验本机是否真的有这个地址
    if [ -n "$SOURCE_IP" ]; then
        if command -v ip >/dev/null 2>&1; then
            if ip addr show 2>/dev/null | grep -qw "$SOURCE_IP"; then
                echo "[$(ts)] ENV source_ip_check=OK ($SOURCE_IP exists on this host)"
            else
                echo "[$(ts)] ENV source_ip_check=WARN ($SOURCE_IP NOT found on this host, 探测可能会失败)"
            fi
        fi
    fi
} >> "$(today_log)" 2>&1

# ============================================================
# 单次 TCP 探测
#   成功：返回 0，并把本次连接耗时(ms)写到全局变量 LAST_RTT
#   失败：返回非 0，并把失败原因写到全局变量 LAST_ERR
# ============================================================
LAST_RTT=""
LAST_ERR=""

# 硬超时包装器：给任意探测命令套一个时间上界，确保永不夯住。
#  - 优先用外部 timeout/gtimeout（-k 1：超时后 1s 内未退再 KILL 强杀）；
#  - 若系统没有 timeout 命令，则用纯 bash 软超时兜底（后台执行 + 轮询 + 强杀），
#    这样即使 nc 的 -w 不生效、/dev/tcp 夯住，也绝不会卡死监控循环。
run_with_timeout() {
    if [ "$HAVE_TIMEOUT" -eq 1 ]; then
        "$TIMEOUT_BIN" -k 1 "$HARD_TIMEOUT" "$@"
        return $?
    fi

    # ---- 纯 bash 软超时兜底 ----
    local __tmp_out __pid __waited=0 __rc
    __tmp_out=$(mktemp 2>/dev/null) || __tmp_out=""
    if [ -n "$__tmp_out" ]; then
        "$@" >"$__tmp_out" 2>&1 &
    else
        "$@" >/dev/null 2>&1 &
    fi
    __pid=$!
    while [ "$__waited" -lt "$HARD_TIMEOUT" ]; do
        kill -0 "$__pid" 2>/dev/null || break
        sleep 1
        __waited=$(( __waited + 1 ))
    done
    if kill -0 "$__pid" 2>/dev/null; then
        # 超时未退：先 TERM，短暂等待后 KILL 强杀，杜绝探测子进程残留
        kill -TERM "$__pid" 2>/dev/null
        sleep 1
        kill -9 "$__pid" 2>/dev/null
        wait "$__pid" 2>/dev/null
        __rc=124
    else
        wait "$__pid" 2>/dev/null
        __rc=$?
    fi
    [ -n "$__tmp_out" ] && { cat "$__tmp_out" 2>/dev/null; rm -f "$__tmp_out" 2>/dev/null; }
    return "$__rc"
}

probe_tcp() {
    LAST_RTT=""
    LAST_ERR=""
    local start_ns end_ns rc out
    start_ns=$(date +%s%N 2>/dev/null)

    case "$PROBE_METHOD" in
        nc)
            local nc_args=()
            [ "$IS_V6" -eq 1 ] && nc_args+=(-6) || nc_args+=(-4)
            nc_args+=(-z)                         # 仅扫描，不发送数据
            [ "$NC_SUPPORTS_W" -eq 1 ] && nc_args+=(-w "$CONNECT_TIMEOUT")
            [ -n "$SOURCE_IP" ] && nc_args+=(-s "$SOURCE_IP")
            # 无论 nc 是否支持 -w，都再用外部 timeout 兜底，防止 SYN 黑洞时无限等待
            out=$(run_with_timeout nc "${nc_args[@]}" "$TARGET" "$PORT" 2>&1)
            rc=$?
            ;;
        python3)
            # python 自身 settimeout 已可控，但 getaddrinfo(DNS) 可能阻塞，外层再用 timeout 兜底
            out=$(run_with_timeout python3 - "$TARGET" "$PORT" "$CONNECT_TIMEOUT" "$SOURCE_IP" "$IS_V6" <<'PYEOF' 2>&1
import socket, sys
target, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
src = sys.argv[4]
is_v6 = sys.argv[5] == "1"
fam = socket.AF_INET6 if is_v6 else socket.AF_INET
try:
    infos = socket.getaddrinfo(target, port, fam, socket.SOCK_STREAM)
except Exception as e:
    print("resolve_error:%s" % e); sys.exit(2)
err = "no-address"
for af, st, proto, cn, sa in infos:
    s = socket.socket(af, st, proto)
    s.settimeout(timeout)
    try:
        if src:
            s.bind((src, 0))
        s.connect(sa)
        s.close()
        sys.exit(0)
    except Exception as e:
        err = str(e)
        try: s.close()
        except Exception: pass
print("connect_error:%s" % err)
sys.exit(1)
PYEOF
)
            rc=$?
            ;;
        devtcp)
            # bash 内建 /dev/tcp（不支持指定源 IP；超时必须配合外部 timeout）
            if [ "$HAVE_TIMEOUT" -eq 1 ]; then
                # 用 CONNECT_TIMEOUT 作 /dev/tcp 的时间上界，-k 1 兜底强杀
                out=$("$TIMEOUT_BIN" -k 1 "$CONNECT_TIMEOUT" bash -c "exec 3<>/dev/tcp/${TARGET}/${PORT}" 2>&1)
                rc=$?
                [ "$rc" -eq 124 ] && out="connect timed out (${CONNECT_TIMEOUT}s)"
            else
                # 最坏情况：无 timeout 命令。/dev/tcp 对黑洞地址会夯到内核默认 SYN 超时。
                # 这里用 bash 内建 read 的超时 + 后台子进程做软超时，确保不会无限夯住。
                ( exec 3<>/dev/tcp/${TARGET}/${PORT} ) 2>/dev/null &
                local dtpid=$!
                local waited=0
                rc=1
                while [ "$waited" -lt "$CONNECT_TIMEOUT" ]; do
                    if ! kill -0 "$dtpid" 2>/dev/null; then
                        wait "$dtpid" 2>/dev/null; rc=$?
                        break
                    fi
                    sleep 1
                    waited=$(( waited + 1 ))
                done
                # 超时仍未结束则强杀，避免子进程泄漏
                if kill -0 "$dtpid" 2>/dev/null; then
                    kill -9 "$dtpid" 2>/dev/null
                    wait "$dtpid" 2>/dev/null
                    rc=124
                    out="connect timed out (${CONNECT_TIMEOUT}s, soft)"
                else
                    out=""
                fi
            fi
            ;;
    esac

    end_ns=$(date +%s%N 2>/dev/null)

    if [ "$rc" -eq 0 ]; then
        # 计算连接耗时（ms），date 不支持 %N 时降级为 N/A
        if [ -n "$start_ns" ] && [ -n "$end_ns" ] && [[ "$start_ns" =~ ^[0-9]+$ ]] && [[ "$end_ns" =~ ^[0-9]+$ ]]; then
            LAST_RTT=$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{printf "%.2f", (e-s)/1000000.0}')
        fi
        return 0
    else
        # 整理失败原因
        local reason
        reason=$(echo "$out" | grep -Ei 'refused|timed out|timeout|unreachable|no route|resolve|Name or service|Connection|could not|failed' | head -1)
        [ -z "$reason" ] && reason=$(echo "$out" | tail -1)
        if [ -z "$reason" ]; then
            # rc=124 是 timeout 命令判定的超时；137 是被 KILL（硬超时强杀）
            if [ "$rc" -eq 124 ]; then
                reason="connect timed out (hard ${HARD_TIMEOUT}s / connect ${CONNECT_TIMEOUT}s)"
            elif [ "$rc" -eq 137 ]; then
                reason="connect killed by hard-timeout (${HARD_TIMEOUT}s)"
            else
                reason="connect failed rc=$rc"
            fi
        fi
        LAST_ERR="$reason"
        return 1
    fi
}

# ----- 主循环：状态机 + 每分钟汇总 -----
miss_count=0
in_outage=0
outage_start_ts=""
outage_start_epoch=0

summary_window=60
window_sent=0
window_lost=0
window_rtt_sum="0"
window_rtt_min=""
window_rtt_max=""
window_start_epoch=$(date +%s)

# 故障持续期间的"心跳"：每 OUTAGE_HEARTBEAT 秒补记一条 OUTAGE ONGOING，
# 这样长时间故障时，即使脚本被 OOM/重启，日志也能清晰看出"仍处于中断中"及已持续时长。
OUTAGE_HEARTBEAT=60
last_outage_hb_epoch=0

# 安全 sleep：即使被信号打断也不会变成忙循环（至少消耗 1s），避免 CPU 飙高。
safe_sleep() {
    sleep "$1" 2>/dev/null || sleep 1 2>/dev/null || true
}

flush_summary() {
    local now_epoch=$1
    [ "$window_sent" -eq 0 ] && return
    local loss_pct
    loss_pct=$(awk -v l="$window_lost" -v s="$window_sent" 'BEGIN{ if(s==0){print "0.00"} else {printf "%.2f", l*100.0/s} }')
    local recv=$(( window_sent - window_lost ))
    local rtt_avg="N/A"
    if [ "$recv" -gt 0 ]; then
        rtt_avg=$(awk -v sum="$window_rtt_sum" -v n="$recv" 'BEGIN{printf "%.2f", sum/n}')
    fi
    log "SUMMARY kind=$KIND target=$TARGET:$PORT window=${summary_window}s sent=$window_sent lost=$window_lost loss=${loss_pct}% connect_min=${window_rtt_min:-N/A} avg=${rtt_avg} max=${window_rtt_max:-N/A} (ms)"
    window_sent=0
    window_lost=0
    window_rtt_sum="0"
    window_rtt_min=""
    window_rtt_max=""
    window_start_epoch=$now_epoch
}

while true; do
    probe_tcp
    PROBE_RC=$?
    now_epoch=$(date +%s)
    window_sent=$(( window_sent + 1 ))

    if [ "$PROBE_RC" -eq 0 ]; then
        # ----- TCP 连接成功 -----
        rtt="$LAST_RTT"
        if [ -n "$rtt" ]; then
            window_rtt_sum=$(awk -v a="$window_rtt_sum" -v b="$rtt" 'BEGIN{printf "%.4f", a+b}')
            if [ -z "$window_rtt_min" ] || awk -v a="$rtt" -v b="$window_rtt_min" 'BEGIN{exit !(a<b)}'; then
                window_rtt_min="$rtt"
            fi
            if [ -z "$window_rtt_max" ] || awk -v a="$rtt" -v b="$window_rtt_max" 'BEGIN{exit !(a>b)}'; then
                window_rtt_max="$rtt"
            fi
        fi

        if [ "$in_outage" -eq 1 ]; then
            duration=$(( now_epoch - outage_start_epoch ))
            recover_ts=$(ts)
            msg="OUTAGE END   kind=$KIND target=$TARGET:$PORT start='$outage_start_ts' end='$recover_ts' duration=${duration}s"
            log "$msg"
            log_outage "$msg"
            in_outage=0
            outage_start_ts=""
            outage_start_epoch=0
        fi
        miss_count=0
    else
        # ----- TCP 连接失败 -----
        window_lost=$(( window_lost + 1 ))
        miss_count=$(( miss_count + 1 ))

        log "FAIL kind=$KIND target=$TARGET:$PORT miss=$miss_count reason='${LAST_ERR:-no-output}'"

        if [ "$in_outage" -eq 0 ] && [ "$miss_count" -ge "$THRESHOLD" ]; then
            outage_start_epoch=$(( now_epoch - (miss_count - 1) * INTERVAL ))
            outage_start_ts=$(date -d "@$outage_start_epoch" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || ts)
            in_outage=1
            last_outage_hb_epoch=$now_epoch
            msg="OUTAGE START kind=$KIND target=$TARGET:$PORT start='$outage_start_ts' miss=$miss_count"
            log "$msg"
            log_outage "$msg"
        fi
    fi

    if [ $(( now_epoch - window_start_epoch )) -ge "$summary_window" ]; then
        flush_summary "$now_epoch"
    fi

    # 故障持续中的心跳：每 OUTAGE_HEARTBEAT 秒补记一条，体现"仍在中断 + 已持续时长"
    if [ "$in_outage" -eq 1 ]; then
        if [ $(( now_epoch - last_outage_hb_epoch )) -ge "$OUTAGE_HEARTBEAT" ]; then
            ongoing=$(( now_epoch - outage_start_epoch ))
            hb="OUTAGE ONGOING kind=$KIND target=$TARGET:$PORT start='$outage_start_ts' elapsed=${ongoing}s miss=$miss_count last_reason='${LAST_ERR:-N/A}'"
            log "$hb"
            log_outage "$hb"
            last_outage_hb_epoch=$now_epoch
        fi
    else
        last_outage_hb_epoch=0
    fi

    safe_sleep "$INTERVAL"
done
