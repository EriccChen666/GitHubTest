#!/bin/bash
# setup_rs_cron.sh — 把 rs_listener.sh 注册成 crontab 常驻监听任务
#
# 作用：在 RS(real server) 机器上，保证 TCP 监听器开机自启、故障重启后自动拉起，
#       不会因为 RS 重启而丢失监听。与探测端 setup_tcp_cron.sh 完全同一套风格。
#
# 用法：
#   安装：./setup_rs_cron.sh add -k <vpc|underlay> -p <端口> [-6] [-b <bind-ip>] [-d <日志目录>] [-m <回显内容>]
#   卸载：./setup_rs_cron.sh del -k <vpc|underlay> -p <端口> [-b <bind-ip>]
#   列表：./setup_rs_cron.sh list
#
# 示例：
#   ./setup_rs_cron.sh add -k vpc      -p 3306
#   ./setup_rs_cron.sh add -k underlay -p 8080 -b 10.0.0.23
#   ./setup_rs_cron.sh del -k vpc      -p 3306
#
# 机制（与 setup_tcp_cron.sh 一致）：
#   - @reboot 开机自启 rs_listener.sh —— RS 重启后监听自动恢复
#   - 每分钟 watchdog：进程不在则拉起（脚本内部 pidfile 互斥，不会重复跑）
#   - 同一 (kind,port,bind) 视为同一任务

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LISTENER="$SCRIPT_DIR/rs_listener.sh"

usage() {
    cat <<EOF
Usage:
  $0 add -k <vpc|underlay> -p <port> [-6] [-b <bind-ip>] [-d <log_dir>] [-m <echo-msg>] [-r <restart-delay>]
  $0 del -k <vpc|underlay> -p <port> [-b <bind-ip>]
  $0 list

Options for add:
  -k <kind>       映射类型：vpc | underlay，必填
  -p <port>       监听端口，必填
  -6              强制 IPv6
  -b <bind-ip>    只在指定本机 IP 上监听（同一端口不同 bind 视为不同任务）
  -d <dir>        日志目录，默认 /var/log/rs_listener
  -m <msg>        连接进来时回显内容（默认不回显）
  -r <delay>      监听退出后重启间隔秒，默认 1
EOF
    exit 1
}

ACTION="${1:-}"
[ -z "$ACTION" ] && usage
shift || true

KIND=""
PORT=""
FORCE_V6=0
BIND_ADDR=""
LOG_DIR=""
ECHO_MSG=""
RESTART_DELAY=""

OPTIND=1
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

# 规范化 kind（list 动作不需要）
if [ "$ACTION" != "list" ]; then
    case "$KIND" in
        vpc|VPC)           KIND="vpc" ;;
        underlay|UNDERLAY|phy|physical) KIND="underlay" ;;
        "") ;;  # 交给各动作校验
        *) echo "ERR: -k 只能是 vpc 或 underlay"; exit 1 ;;
    esac
fi

CRON_TAG_PREFIX="# RS_LISTENER_TAG="

# tag 唯一标识一个任务：kind + port (+ bind)
make_tag() {
    local base="${CRON_TAG_PREFIX}${KIND}:${PORT}"
    if [ -n "$BIND_ADDR" ]; then
        echo "${base}@${BIND_ADDR}"
    else
        echo "$base"
    fi
}

build_cmd() {
    local cmd="$LISTENER -k $KIND -p $PORT"
    [ "$FORCE_V6" -eq 1 ]   && cmd="$cmd -6"
    [ -n "$BIND_ADDR" ]     && cmd="$cmd -b $BIND_ADDR"
    [ -n "$LOG_DIR" ]       && cmd="$cmd -d $LOG_DIR"
    [ -n "$ECHO_MSG" ]      && cmd="$cmd -m '$ECHO_MSG'"
    [ -n "$RESTART_DELAY" ] && cmd="$cmd -r $RESTART_DELAY"
    echo "$cmd"
}

cmd_add() {
    [ -z "$KIND" ] && usage
    [ -z "$PORT" ] && usage
    [ ! -x "$LISTENER" ] && { echo "ERR: $LISTENER 不存在或未授予执行权限（chmod +x rs_listener.sh）"; exit 2; }
    command -v nc >/dev/null 2>&1 || { echo "ERR: 本机未安装 nc(netcat)，无法启动监听"; exit 2; }

    local CMD; CMD=$(build_cmd)
    local TAG; TAG=$(make_tag)

    local CRON_TMP; CRON_TMP=$(mktemp)
    crontab -l 2>/dev/null | awk -v tag="$TAG" '
        BEGIN{ skip=0 }
        { if ($0==tag){ skip=2; next } if (skip>0){ skip--; next } print }
    ' > "$CRON_TMP" || true

    {
        echo "$TAG"
        echo "@reboot $CMD >/dev/null 2>&1"
        echo "* * * * * $CMD >/dev/null 2>&1"
    } >> "$CRON_TMP"

    crontab "$CRON_TMP"
    rm -f "$CRON_TMP"
    echo "[OK] 已添加 cron 任务，kind=$KIND port=$PORT${BIND_ADDR:+ bind=$BIND_ADDR}"
    echo "     命令: $CMD"

    # 立即起一份
    eval "nohup $CMD >/dev/null 2>&1 &"
    echo "[OK] 已立即在后台启动一份监听进程 pid=$!"
}

cmd_del() {
    [ -z "$KIND" ] && usage
    [ -z "$PORT" ] && usage

    local TAG; TAG=$(make_tag)
    local CRON_TMP; CRON_TMP=$(mktemp)
    local CUR; CUR=$(crontab -l 2>/dev/null || true)

    if [ -z "$CUR" ]; then
        echo "[WARN] 当前 crontab 为空，无可删除"
        rm -f "$CRON_TMP"
        return 0
    fi

    if [ -n "$BIND_ADDR" ]; then
        echo "$CUR" | awk -v tag="$TAG" '
            BEGIN { skip = 0 }
            {
                if ($0 == tag) { skip = 2; next }
                if (skip > 0)  { skip--; next }
                print
            }
        ' > "$CRON_TMP"
    else
        local TAG_BASE="${CRON_TAG_PREFIX}${KIND}:${PORT}"
        echo "$CUR" | awk -v base="$TAG_BASE" '
            BEGIN { skip = 0 }
            {
                if ($0 == base || index($0, base "@") == 1) { skip = 2; next }
                if (skip > 0) { skip--; next }
                print
            }
        ' > "$CRON_TMP"
    fi

    # 兜底：按命令关键词二次过滤（fixed-string）
    local KIND_PAT=" -k ${KIND} "
    local PORT_PAT=" -p ${PORT} "
    local PORT_PAT_END=" -p ${PORT}"
    local BIND_PAT=""
    [ -n "$BIND_ADDR" ] && BIND_PAT=" -b ${BIND_ADDR}"
    local CRON_TMP2; CRON_TMP2=$(mktemp)
    awk -v kp="$KIND_PAT" -v pp="$PORT_PAT" -v ppe="$PORT_PAT_END" -v bp="$BIND_PAT" '
        {
            if (index($0, "rs_listener.sh") > 0) {
                hit_k = (index($0, kp) > 0)
                hit_p = 0
                if (index($0, pp) > 0) hit_p = 1
                else {
                    line_end = substr($0, length($0) - length(ppe) + 1)
                    if (line_end == ppe) hit_p = 1
                }
                if (hit_k && hit_p) {
                    if (bp == "") { next }
                    else { if (index($0, bp) > 0) next }
                }
            }
            print
        }
    ' "$CRON_TMP" > "$CRON_TMP2"

    local BEFORE_LINES AFTER_LINES
    BEFORE_LINES=$(echo "$CUR" | wc -l | tr -d ' ')
    AFTER_LINES=$(wc -l < "$CRON_TMP2" | tr -d ' ')

    if [ "$BEFORE_LINES" = "$AFTER_LINES" ]; then
        echo "[WARN] 未在 crontab 中找到 kind=$KIND port=$PORT${BIND_ADDR:+ bind=$BIND_ADDR} 的任务"
        echo "       当前 crontab 中相关条目："
        echo "$CUR" | grep -E "RS_LISTENER_TAG|rs_listener.sh" || echo "       (无)"
        rm -f "$CRON_TMP" "$CRON_TMP2"
        return 1
    fi

    crontab "$CRON_TMP2"
    rm -f "$CRON_TMP" "$CRON_TMP2"
    echo "[OK] 已从 crontab 删除 kind=$KIND port=$PORT${BIND_ADDR:+ bind=$BIND_ADDR} 的任务（删除 $((BEFORE_LINES - AFTER_LINES)) 行）"

    # 杀掉监听进程（含其 nc 子进程）
    if [ -n "$BIND_ADDR" ]; then
        pkill -f "rs_listener.sh.*-k ${KIND}.*-p ${PORT}.*-b ${BIND_ADDR}" 2>/dev/null \
            && echo "[OK] 已停止 rs_listener 进程 (kind=$KIND port=$PORT bind=$BIND_ADDR)"
    else
        pkill -f "rs_listener.sh.*-k ${KIND}.*-p ${PORT}( |$)" 2>/dev/null \
            && echo "[OK] 已停止 rs_listener 进程 (kind=$KIND port=$PORT)"
    fi

    # 清理 pidfile
    RUN_USER="$(id -un 2>/dev/null || whoami)"
    LOG_DIR_REAL="${LOG_DIR:-/var/log/rs_listener}"
    if [ -n "$BIND_ADDR" ]; then
        SAFE_BIND=$(echo "$BIND_ADDR" | tr ':/' '__')
        PIDFILE_PATH="${LOG_DIR_REAL}/.rs_${KIND}_${RUN_USER}_${PORT}_bind_${SAFE_BIND}.pid"
        [ -f "$PIDFILE_PATH" ] && rm -f "$PIDFILE_PATH" && echo "[OK] 已清理 pidfile: $PIDFILE_PATH"
    else
        local cleaned=0
        for f in "${LOG_DIR_REAL}/.rs_${KIND}_${RUN_USER}_${PORT}.pid" \
                 "${LOG_DIR_REAL}/.rs_${KIND}_${RUN_USER}_${PORT}"_bind_*.pid; do
            [ -f "$f" ] && rm -f "$f" && echo "[OK] 已清理 pidfile: $f" && cleaned=$((cleaned+1))
        done
        [ "$cleaned" -eq 0 ] && true
    fi
}

cmd_list() {
    echo "===== 当前 rs_listener cron 任务 ====="
    crontab -l 2>/dev/null | grep -E "${CRON_TAG_PREFIX}|rs_listener.sh" || echo "(无)"
    echo
    echo "===== 当前正在运行的 rs_listener 进程 ====="
    pgrep -af 'rs_listener.sh' || echo "(无)"
    echo
    echo "===== 本机正在监听的端口 (ss -ltn) ====="
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null || echo "(ss 执行失败)"
    else
        echo "(无 ss 命令)"
    fi
}

case "$ACTION" in
    add)  cmd_add ;;
    del)  cmd_del ;;
    list) cmd_list ;;
    *)    usage ;;
esac
