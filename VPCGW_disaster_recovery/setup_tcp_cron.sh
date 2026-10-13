#!/bin/bash
# setup_tcp_cron.sh — 把 tcp_monitor.sh 注册成 crontab 定时监控任务
#
# 适用：VPC 私有网络服务映射 (kind=vpc) / 物理网络服务映射 (kind=underlay)
#
# 用法：
#   安装：./setup_tcp_cron.sh add -k <vpc|underlay> -t <目的地址> -p <端口> [-6] [-d <日志目录>] [-i <间隔>] [-T <阈值>] [-w <超时>] [-S <源IP>]
#   卸载：./setup_tcp_cron.sh del -k <vpc|underlay> -t <目的地址> -p <端口> [-S <源IP>]
#   列表：./setup_tcp_cron.sh list
#
# 示例：
#   ./setup_tcp_cron.sh add -k vpc      -t 10.0.0.23  -p 3306
#   ./setup_tcp_cron.sh add -k underlay -t 172.16.5.8 -p 8080 -S 10.0.0.5
#   ./setup_tcp_cron.sh del -k vpc      -t 10.0.0.23  -p 3306
#
# 机制（与 DC 的 setup_ping_cron.sh 一致）：
#   - @reboot 开机自启 tcp_monitor.sh
#   - 每分钟 watchdog：若进程不在则拉起（脚本内部有 pidfile 互斥，不会重复跑）
#   - 同一 (kind,target,port,src) 视为同一任务；不同任意一项即视为不同任务

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MONITOR="$SCRIPT_DIR/tcp_monitor.sh"

usage() {
    cat <<EOF
Usage:
  $0 add -k <vpc|underlay> -t <target> -p <port> [-6] [-d <log_dir>] [-i <interval>] [-T <threshold>] [-w <timeout>] [-S <src-ip>]
  $0 del -k <vpc|underlay> -t <target> -p <port> [-S <src-ip>]
  $0 list

Options for add:
  -k <kind>       映射类型：vpc | underlay，必填
  -t <target>     目的地址（IPv4/IPv6 或域名），必填
  -p <port>       目的 TCP 端口，必填
  -6              强制 IPv6
  -d <dir>        日志目录，默认 /var/log/tcp_monitor
  -i <interval>   探测间隔秒，默认 1
  -T <threshold>  连续失败判中断阈值，默认 3
  -w <timeout>    单次 TCP 连接超时秒，默认 2
  -S <src-ip>     可选：指定源 IP（同一 target:port 的不同源 IP 视为不同任务）
EOF
    exit 1
}

ACTION="${1:-}"
[ -z "$ACTION" ] && usage
[ "$ACTION" = "list" ] || shift || true
[ "$ACTION" = "list" ] && shift || true

KIND=""
TARGET=""
PORT=""
FORCE_V6=0
LOG_DIR=""
INTERVAL=""
THRESHOLD=""
CONNECT_TIMEOUT=""
SOURCE_IP=""

OPTIND=1
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

# 规范化 kind（list 动作不需要）
if [ "$ACTION" != "list" ]; then
    case "$KIND" in
        vpc|VPC)           KIND="vpc" ;;
        underlay|UNDERLAY|phy|physical) KIND="underlay" ;;
        "") ;;  # 交给下面各动作校验
        *) echo "ERR: -k 只能是 vpc 或 underlay"; exit 1 ;;
    esac
fi

CRON_TAG_PREFIX="# TCP_MONITOR_TAG="

# tag 需能唯一标识一个任务：kind + target + port (+ src)
make_tag() {
    local base="${CRON_TAG_PREFIX}${KIND}:${TARGET}:${PORT}"
    if [ -n "$SOURCE_IP" ]; then
        echo "${base}@${SOURCE_IP}"
    else
        echo "$base"
    fi
}

build_cmd() {
    local cmd="$MONITOR -k $KIND -t $TARGET -p $PORT"
    [ "$FORCE_V6" -eq 1 ]      && cmd="$cmd -6"
    [ -n "$LOG_DIR" ]          && cmd="$cmd -d $LOG_DIR"
    [ -n "$INTERVAL" ]         && cmd="$cmd -i $INTERVAL"
    [ -n "$THRESHOLD" ]        && cmd="$cmd -T $THRESHOLD"
    [ -n "$CONNECT_TIMEOUT" ]  && cmd="$cmd -w $CONNECT_TIMEOUT"
    [ -n "$SOURCE_IP" ]        && cmd="$cmd -S $SOURCE_IP"
    echo "$cmd"
}

cmd_add() {
    [ -z "$KIND" ]   && usage
    [ -z "$TARGET" ] && usage
    [ -z "$PORT" ]   && usage
    [ ! -x "$MONITOR" ] && { echo "ERR: $MONITOR 不存在或未授予执行权限（chmod +x tcp_monitor.sh）"; exit 2; }

    local CMD; CMD=$(build_cmd)
    local TAG; TAG=$(make_tag)

    # 取现有 crontab；只移除完全相同 tag 的旧记录
    local CRON_TMP; CRON_TMP=$(mktemp)
    crontab -l 2>/dev/null | awk -v tag="$TAG" '
        BEGIN{ skip=0 }
        { if ($0==tag){ skip=2; next } if (skip>0){ skip--; next } print }
    ' > "$CRON_TMP" || true

    # 写入三行：tag / @reboot / 每分钟 watchdog
    {
        echo "$TAG"
        echo "@reboot $CMD >/dev/null 2>&1"
        echo "* * * * * $CMD >/dev/null 2>&1"
    } >> "$CRON_TMP"

    crontab "$CRON_TMP"
    rm -f "$CRON_TMP"
    echo "[OK] 已添加 cron 任务，kind=$KIND target=$TARGET:$PORT${SOURCE_IP:+ src=$SOURCE_IP}"
    echo "     命令: $CMD"

    # 立即起一份，不用等下一分钟
    nohup $CMD >/dev/null 2>&1 &
    echo "[OK] 已立即在后台启动一份监控进程 pid=$!"
}

cmd_del() {
    [ -z "$KIND" ]   && usage
    [ -z "$TARGET" ] && usage
    [ -z "$PORT" ]   && usage

    local TAG; TAG=$(make_tag)
    local CRON_TMP; CRON_TMP=$(mktemp)
    local CUR; CUR=$(crontab -l 2>/dev/null || true)

    if [ -z "$CUR" ]; then
        echo "[WARN] 当前 crontab 为空，无可删除"
        rm -f "$CRON_TMP"
        return 0
    fi

    # 用 awk 精准删除：匹配 tag 行，并连带删除紧随其后的 2 行 cron 命令
    # 指定 -S：只删 "TAG=kind:target:port@src" 精确 tag；
    # 未指定 -S：把 "TAG=kind:target:port" 及其 "@*" 变体都删
    if [ -n "$SOURCE_IP" ]; then
        echo "$CUR" | awk -v tag="$TAG" '
            BEGIN { skip = 0 }
            {
                if ($0 == tag) { skip = 2; next }
                if (skip > 0)  { skip--; next }
                print
            }
        ' > "$CRON_TMP"
    else
        local TAG_BASE="${CRON_TAG_PREFIX}${KIND}:${TARGET}:${PORT}"
        echo "$CUR" | awk -v base="$TAG_BASE" '
            BEGIN { skip = 0 }
            {
                if ($0 == base || index($0, base "@") == 1) { skip = 2; next }
                if (skip > 0) { skip--; next }
                print
            }
        ' > "$CRON_TMP"
    fi

    # 兜底：按命令关键词二次过滤（fixed-string，避免 IPv6 的 ':' 被当正则）
    local SAFE_PAT_T=" -t ${TARGET} "
    local SAFE_PAT_P=" -p ${PORT} "
    local SAFE_PAT_P_END=" -p ${PORT}"      # 端口在行尾（无后续参数）的情况
    local SRC_PAT=""
    [ -n "$SOURCE_IP" ] && SRC_PAT=" -S ${SOURCE_IP}"
    local KIND_PAT=" -k ${KIND} "
    local CRON_TMP2; CRON_TMP2=$(mktemp)
    awk -v pt="$SAFE_PAT_T" -v pp="$SAFE_PAT_P" -v ppe="$SAFE_PAT_P_END" \
        -v sp="$SRC_PAT" -v kp="$KIND_PAT" '
        {
            if (index($0, "tcp_monitor.sh") > 0) {
                hit_k = (index($0, kp) > 0)
                hit_t = (index($0, pt) > 0)
                hit_p = 0
                if (index($0, pp) > 0) hit_p = 1
                else {
                    line_end = substr($0, length($0) - length(ppe) + 1)
                    if (line_end == ppe) hit_p = 1
                }
                if (hit_k && hit_t && hit_p) {
                    if (sp == "") { next }
                    else { if (index($0, sp) > 0) next }
                }
            }
            print
        }
    ' "$CRON_TMP" > "$CRON_TMP2"

    local BEFORE_LINES AFTER_LINES
    BEFORE_LINES=$(echo "$CUR" | wc -l | tr -d ' ')
    AFTER_LINES=$(wc -l < "$CRON_TMP2" | tr -d ' ')

    if [ "$BEFORE_LINES" = "$AFTER_LINES" ]; then
        echo "[WARN] 未在 crontab 中找到 kind=$KIND target=$TARGET:$PORT${SOURCE_IP:+ src=$SOURCE_IP} 的任务（可能已删除或拼写不一致）"
        echo "       当前 crontab 中相关条目："
        echo "$CUR" | grep -E "TCP_MONITOR_TAG|tcp_monitor.sh" || echo "       (无)"
        rm -f "$CRON_TMP" "$CRON_TMP2"
        return 1
    fi

    crontab "$CRON_TMP2"
    rm -f "$CRON_TMP" "$CRON_TMP2"
    echo "[OK] 已从 crontab 删除 kind=$KIND target=$TARGET:$PORT${SOURCE_IP:+ src=$SOURCE_IP} 的任务（删除 $((BEFORE_LINES - AFTER_LINES)) 行）"

    # 杀掉运行进程
    if [ -n "$SOURCE_IP" ]; then
        if pkill -f "tcp_monitor.sh .* -t ${TARGET} .* -p ${PORT}( .* -S ${SOURCE_IP}|.* -S ${SOURCE_IP})" 2>/dev/null \
           || pkill -f "tcp_monitor.sh.*-k ${KIND}.*-t ${TARGET}.*-p ${PORT}.*-S ${SOURCE_IP}" 2>/dev/null; then
            echo "[OK] 已停止运行中的 tcp_monitor 进程 (kind=$KIND target=$TARGET:$PORT src=$SOURCE_IP)"
        fi
    else
        if pkill -f "tcp_monitor.sh.*-k ${KIND}.*-t ${TARGET}.*-p ${PORT}( |$)" 2>/dev/null; then
            echo "[OK] 已停止运行中的 tcp_monitor 进程 (kind=$KIND target=$TARGET:$PORT)"
        fi
    fi

    # 清理 pidfile
    RUN_USER="$(id -un 2>/dev/null || whoami)"
    SAFE_TARGET=$(echo "$TARGET" | tr ':/' '__')
    LOG_DIR_REAL="${LOG_DIR:-/var/log/tcp_monitor}"
    if [ -n "$SOURCE_IP" ]; then
        SAFE_SRC=$(echo "$SOURCE_IP" | tr ':/' '__')
        PIDFILE_PATH="${LOG_DIR_REAL}/.tcp_${KIND}_${RUN_USER}_${SAFE_TARGET}_${PORT}_from_${SAFE_SRC}.pid"
        if [ -f "$PIDFILE_PATH" ]; then
            rm -f "$PIDFILE_PATH"
            echo "[OK] 已清理 pidfile: $PIDFILE_PATH"
        fi
    else
        local cleaned=0
        for f in "${LOG_DIR_REAL}/.tcp_${KIND}_${RUN_USER}_${SAFE_TARGET}_${PORT}.pid" \
                 "${LOG_DIR_REAL}/.tcp_${KIND}_${RUN_USER}_${SAFE_TARGET}_${PORT}"_from_*.pid; do
            [ -f "$f" ] && rm -f "$f" && echo "[OK] 已清理 pidfile: $f" && cleaned=$((cleaned+1))
        done
        [ "$cleaned" -eq 0 ] && true
    fi
}

cmd_list() {
    echo "===== 当前 tcp_monitor cron 任务 ====="
    crontab -l 2>/dev/null | grep -E "${CRON_TAG_PREFIX}|tcp_monitor.sh" || echo "(无)"
    echo
    echo "===== 当前正在运行的 tcp_monitor 进程 ====="
    pgrep -af 'tcp_monitor.sh' || echo "(无)"
}

case "$ACTION" in
    add)  cmd_add ;;
    del)  cmd_del ;;
    list) cmd_list ;;
    *)    usage ;;
esac
