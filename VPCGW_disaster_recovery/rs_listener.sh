#!/bin/bash
# rs_listener.sh — RS(real server) 端常驻 TCP 监听器
#
# 作用：
#   在 RS 机器上固定监听某个端口，作为 tcp_monitor.sh（探测端）的"被探测目标"。
#   配合 VPC 私有网络服务映射 / 物理网络服务映射的连通性探测与打流。
#   RS 故障重启后，靠 setup_rs_cron.sh 的 crontab(@reboot + 每分钟 watchdog)
#   把本脚本重新拉起，保证"端口始终有东西在 listen"，不会丢失监听。
#
# 用法：
#   ./rs_listener.sh -k <vpc|underlay> -p <端口> [options]
#
# 示例：
#   ./rs_listener.sh -k vpc      -p 3306
#   ./rs_listener.sh -k underlay -p 8080 -b 10.0.0.23          # 只在指定本机 IP 上监听
#   ./rs_listener.sh -k vpc      -p 443  -6                    # IPv6 监听
#   ./rs_listener.sh -k vpc      -p 9000 -m "RS-OK\n"          # 连接时回显一段数据
#
# 行为（与探测端 tcp_monitor.sh 风格一致）：
#   - 内部 while true 循环，一个连接处理完后立即重新监听，保证端口持续可连
#   - 启动时打印环境信息（hostname/kernel/nc版本/监听地址端口）
#   - 每次有探测/连接进来记一行 ACCEPT，监听异常退出记 LISTEN RESTART
#   - 每 60s 输出一次 SUMMARY（本窗口接入次数 / 监听重启次数）
#   - pidfile 单实例互斥，防止 crontab 重复拉起
#   - 每日全量日志：LOG_DIR/rs_<kind>_<user>_<port>_YYYYMMDD.log

set -u
# cron 启动时 PATH 只有 /usr/bin:/bin，ip/ss 等在 sbin 下会找不到，导致环境信息缺失
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin"

KIND=""                  # vpc | underlay
PORT=""
FORCE_V6=0
BIND_ADDR=""             # 可选：只在指定本机 IP 上监听（默认所有地址）
LOG_DIR="/var/log/rs_listener"
ECHO_MSG=""              # 可选：有连接进来时回显的内容（默认不回显，纯握手）
RESTART_DELAY=1          # 监听进程退出后重启间隔秒（防止异常时忙循环）

usage() {
    cat <<EOF
Usage: $0 -k <vpc|underlay> -p <port> [options]
  -k <kind>       映射类型：vpc（VPC私有网络服务映射）| underlay（物理网络服务映射），必填
  -p <port>       监听的 TCP 端口，必填
  -6              强制 IPv6 监听
  -b <bind-addr>  只在指定本机 IP 上监听（默认监听所有地址）
  -d <dir>        日志目录，默认 /var/log/rs_listener
  -m <msg>        有连接进来时回显的内容（默认不回显，仅接受握手）
  -r <delay>      监听进程退出后的重启间隔秒，默认 1
  -h              显示帮助
EOF
    exit 1
}

while getopts "k:p:6b:d:m:r:h" opt; do
    case "$opt" in
        k) KIND="$OPTARG" ;;
        p) PORT="$OPTARG" ;;
        6) FORCE_V6=1 ;;
        b) BIND_ADDR="$OPTARG" ;;
        d) LOG_DIR="$OPTARG" ;;
        m) ECHO_MSG="$OPTARG" ;;
        r) RESTART_DELAY="$OPTARG" ;;
        h|*) usage ;;
    esac
done

[ -z "$KIND" ] && usage
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

IS_V6=0
[ "$FORCE_V6" -eq 1 ] && IS_V6=1

# ----- 必须有 nc -----
if ! command -v nc >/dev/null 2>&1; then
    echo "ERR: 本机未安装 nc(netcat)，无法启动监听。请先安装（如 yum install nmap-ncat / apt install netcat-openbsd）"
    exit 2
fi

# 探测 nc 变体：OpenBSD 版用 -l -p 或 -l；传统/GNU 版用 -l -p；busybox 用 -ll
# 统一用 "nc -l <port>" 或 "nc -l -p <port>" 两种形态，启动时自适应
NC_HELP="$(nc -h 2>&1)"

# ----- 准备日志目录与文件 -----
mkdir -p "$LOG_DIR" 2>/dev/null || true
RUN_USER="$(id -un 2>/dev/null || whoami)"
if [ -n "$BIND_ADDR" ]; then
    SAFE_BIND=$(echo "$BIND_ADDR" | tr ':/' '__')
    FILE_TAG="${KIND}_${RUN_USER}_${PORT}_bind_${SAFE_BIND}"
else
    FILE_TAG="${KIND}_${RUN_USER}_${PORT}"
fi
PIDFILE="$LOG_DIR/.rs_${FILE_TAG}.pid"

# ----- 单实例保护：防止 crontab 重复拉起 -----
# 不能只看 kill -0：设备重启后 pidfile 里的旧 PID 可能被别的进程复用，
# 那样脚本会误判"已在运行"而永远起不来。所以还要核对该 PID 确实是本脚本且端口相同。
pid_is_self() {
    local p="$1" cmd
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null || return 1
    [ -r "/proc/$p/cmdline" ] || return 0   # 无 /proc 的系统退回旧逻辑
    cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
    case "$cmd" in
        *rs_listener.sh*"-p $PORT"*) return 0 ;;
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

# 退出时清理 pidfile + 残留 nc 子进程
NC_CHILD_PID=""
cleanup() {
    [ -n "$NC_CHILD_PID" ] && kill "$NC_CHILD_PID" 2>/dev/null
    rm -f "$PIDFILE"
    exit 0
}
trap cleanup INT TERM EXIT

ts() { date '+%Y-%m-%d %H:%M:%S'; }

today_log() {
    echo "$LOG_DIR/rs_${FILE_TAG}_$(date '+%Y%m%d').log"
}

ensure_log_dir() {
    [ -d "$LOG_DIR" ] || mkdir -p "$LOG_DIR" 2>/dev/null || true
}

log() {
    ensure_log_dir
    echo "[$(ts)] $*" >> "$(today_log)" 2>/dev/null || true
}

# ============================================================
# 选择一条能真正 listen 起来的 nc 监听命令（存到数组 NC_CMD）
#
# 不同 nc 变体监听语法差异很大，光解析 -h 容易猜错（例如 BSD/macOS 的 -p 是源端口）：
#   - BSD/macOS nc / ncat(nmap)：nc -l <port>            （端口是位置参数）
#   - OpenBSD nc                ：nc -l <port>
#   - 传统 nc (nc-traditional)  ：nc -l -p <port>
# 这里改为"实战探测"：分别尝试几种候选语法，谁能在本端口起监听且能被连上，就用谁。
# 探测端只看 TCP 握手，所以监听内容不重要；可选 -m 回显。
# ============================================================
NC_STYLE=""        # positional | dash_p
build_nc_cmd() {
    NC_CMD=(nc)
    [ "$IS_V6" -eq 1 ] && NC_CMD+=(-6) || NC_CMD+=(-4)
    NC_CMD+=(-l)
    [ -n "$BIND_ADDR" ] && NC_CMD+=(-s "$BIND_ADDR")
    if [ "$NC_STYLE" = "dash_p" ]; then
        NC_CMD+=(-p "$PORT")
    else
        NC_CMD+=("$PORT")
    fi
}

# 探测某种监听语法是否可用：起一个监听 → 用客户端 nc 去连 → 能连通即可用
try_listen_style() {
    local style="$1" probe_port="$2"
    local lcmd=(nc)
    [ "$IS_V6" -eq 1 ] && lcmd+=(-6) || lcmd+=(-4)
    lcmd+=(-l)
    [ -n "$BIND_ADDR" ] && lcmd+=(-s "$BIND_ADDR")
    if [ "$style" = "dash_p" ]; then
        lcmd+=(-p "$probe_port")
    else
        lcmd+=("$probe_port")
    fi

    "${lcmd[@]}" >/dev/null 2>&1 &
    local lpid=$!
    sleep 1
    # 监听进程还活着才有意义（瞬间退出说明语法/端口有问题）
    if ! kill -0 "$lpid" 2>/dev/null; then
        wait "$lpid" 2>/dev/null
        return 1
    fi
    local connect_host="127.0.0.1"
    [ "$IS_V6" -eq 1 ] && connect_host="::1"
    [ -n "$BIND_ADDR" ] && connect_host="$BIND_ADDR"
    local ok=1
    if nc -z -w 2 "$connect_host" "$probe_port" >/dev/null 2>&1; then
        ok=0
    fi
    kill "$lpid" 2>/dev/null
    wait "$lpid" 2>/dev/null
    return "$ok"
}

# 自动选择监听语法：用一个临时高位端口做探测，避免占用真实业务端口
detect_nc_style() {
    local probe_port=$(( (RANDOM % 10000) + 40000 ))
    if try_listen_style positional "$probe_port"; then
        NC_STYLE="positional"
        return 0
    fi
    probe_port=$(( (RANDOM % 10000) + 40000 ))
    if try_listen_style dash_p "$probe_port"; then
        NC_STYLE="dash_p"
        return 0
    fi
    # 两种都没探到：默认用 positional（现代 nc 主流），并记告警
    NC_STYLE="positional"
    return 1
}

# ===== 启动时打环境信息 =====
KIND_DESC=$([ "$KIND" = "vpc" ] && echo "VPC私有网络服务映射" || echo "物理网络服务映射")
# 先自动探测本机 nc 的监听语法，再构造最终监听命令
NC_STYLE_OK=0
detect_nc_style && NC_STYLE_OK=1
build_nc_cmd
log "========== rs_listener START kind=$KIND($KIND_DESC) user=$RUN_USER port=$PORT bind=${BIND_ADDR:-ANY} is_v6=$IS_V6 echo='${ECHO_MSG:-none}' nc_style=$NC_STYLE =========="
{
    echo "[$(ts)] ENV host=$(hostname 2>/dev/null) kernel=$(uname -r 2>/dev/null) os=$(uname -s 2>/dev/null)"
    echo "[$(ts)] ENV nc_version=$(nc -h 2>&1 | head -1)"
    echo "[$(ts)] ENV nc_style=$NC_STYLE detected=$NC_STYLE_OK listen_cmd=${NC_CMD[*]}"
    [ "$NC_STYLE_OK" -eq 0 ] && echo "[$(ts)] ENV WARN 未能自动探明 nc 监听语法，已回退默认 positional，如监听异常请检查 nc 变体"
    # 列出本机已有的监听端口，便于确认端口是否被占用
    if command -v ss >/dev/null 2>&1; then
        echo "[$(ts)] ENV existing_listen_on_$PORT=$(ss -ltn 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {print $4}' | paste -sd, - 2>/dev/null)"
    fi
} >> "$(today_log)" 2>&1

# ----- 主循环：保持端口持续监听 -----
# nc -l 处理完一个连接通常会退出，这里用 while true 立即重新监听，
# 保证"端口始终有东西 listen"。监听进程异常退出也会被重启并记日志。
accept_count=0          # 累计接入次数（近似：每次 nc 返回视为处理了一次连接）
restart_count=0         # 监听重启次数

summary_window=60
window_accept=0
window_restart=0
window_start_epoch=$(date +%s)

flush_summary() {
    local now_epoch=$1
    local state="ACTIVE"
    [ "$window_accept" -eq 0 ] && state="IDLE(本窗口无连接接入,上游可能故障)"
    log "SUMMARY kind=$KIND port=$PORT window=${summary_window}s accepts=$window_accept listen_restarts=$window_restart total_accepts=$accept_count state=$state"
    window_accept=0
    window_restart=0
    window_start_epoch=$now_epoch
}

log "LISTEN START kind=$KIND port=$PORT bind=${BIND_ADDR:-ANY} 开始持续监听"

while true; do
    start_epoch=$(date +%s)

    # 起一次监听：有连接进来→处理（可选回显）→nc 退出→本轮结束
    if [ -n "$ECHO_MSG" ]; then
        # 回显模式：把 ECHO_MSG 通过管道喂给 nc（连接建立后发出去）
        printf '%b' "$ECHO_MSG" | "${NC_CMD[@]}" >/dev/null 2>&1 &
    else
        # 纯握手模式：丢弃对端数据即可
        "${NC_CMD[@]}" >/dev/null 2>&1 &
    fi
    NC_CHILD_PID=$!

    # 等这次监听结束（有连接被处理，或被外部打断）。
    # 不能直接阻塞 wait：故障期间没有连接进来，nc 会一直不返回，导致 SUMMARY/心跳全部停摆。
    # 改为每秒轮询一次，期间照常按窗口输出 SUMMARY，保证接收端日志在故障期间持续记录。
    # 轮询间隔用 0.2s（不支持小数 sleep 时退回 1s），尽量缩短 nc 退出到重新 listen 的空窗，避免探测端误判 refused。
    while kill -0 "$NC_CHILD_PID" 2>/dev/null; do
        sleep 0.2 2>/dev/null || sleep 1
        now_epoch=$(date +%s)
        if [ $(( now_epoch - window_start_epoch )) -ge "$summary_window" ]; then
            flush_summary "$now_epoch"
        fi
    done
    wait "$NC_CHILD_PID" 2>/dev/null
    NC_RC=$?
    NC_CHILD_PID=""
    end_epoch=$(date +%s)

    # nc 正常处理一个连接后退出 → 记一次 ACCEPT
    # （纯监听场景下 nc 退出几乎都对应"有一次连接进来或探测握手"）
    accept_count=$(( accept_count + 1 ))
    window_accept=$(( window_accept + 1 ))
    log "ACCEPT kind=$KIND port=$PORT rc=$NC_RC held=$(( end_epoch - start_epoch ))s total=$accept_count"

    # 如果 nc 几乎瞬间就退出（可能端口被占用/权限不足/参数不兼容），
    # 说明不是正常的"处理完连接"，而是监听本身起不来 → 按异常处理并告警
    if [ $(( end_epoch - start_epoch )) -eq 0 ] && [ "$NC_RC" -ne 0 ]; then
        restart_count=$(( restart_count + 1 ))
        window_restart=$(( window_restart + 1 ))
        log "LISTEN RESTART kind=$KIND port=$PORT rc=$NC_RC 监听疑似未成功建立(端口被占用/权限/参数不兼容?)，${RESTART_DELAY}s 后重试 restarts=$restart_count"
        sleep "$RESTART_DELAY" 2>/dev/null || sleep 1
    fi

    # 每 summary_window 秒输出一次汇总
    now_epoch=$(date +%s)
    if [ $(( now_epoch - window_start_epoch )) -ge "$summary_window" ]; then
        flush_summary "$now_epoch"
    fi
done
