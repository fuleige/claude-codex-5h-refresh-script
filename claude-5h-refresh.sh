#!/usr/bin/env bash
# claude-5h-refresh: 每天在固定的北京时间 (Asia/Shanghai) 给 Claude 发一条极短的消息，
# 让 5 小时用量窗口从这些时间点开始计时。
#
# 独立脚本，只依赖 bash、curl 和已登录的 claude CLI，可以复制到任意 Linux 机器使用。
# 时间点按 UTC+8 计算，与本机时区设置无关。
#
# 用法:
#   claude-5h-refresh.sh start [--proxy URL]    检测代理（不通会询问），保存配置，启动后台守护进程
#   claude-5h-refresh.sh stop                   停止守护进程
#   claude-5h-refresh.sh restart [--proxy URL]  重启
#   claude-5h-refresh.sh status                 查看运行状态和下次触发时间
#   claude-5h-refresh.sh test [--proxy URL]     立即发送一次消息，验证整条链路
#   claude-5h-refresh.sh check-proxy [--proxy URL]  只检测代理（不通会询问）
#   claude-5h-refresh.sh logs [行数]            查看日志
#   claude-5h-refresh.sh ensure                 未运行则静默启动（给 ~/.bashrc 自启用）
#   claude-5h-refresh.sh enable-autostart       在 ~/.bashrc 里加入自启
#   claude-5h-refresh.sh disable-autostart      从 ~/.bashrc 里移除自启
#
# --proxy 只接受 http:// 或 https:// 代理（Claude Code 不支持 SOCKS），或 direct 表示直连。
# 代理检查：先确认代理端口已开启，再经代理访问 Google，两步都通过才继续；每次触发前也会检查。
# 配置、日志、状态默认放在 ~/.claude-5h-refresh/，可用环境变量 CLAUDE_5H_HOME 改位置。

set -uo pipefail

APP=claude-5h-refresh
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
STATE_DIR="${CLAUDE_5H_HOME:-$HOME/.claude-5h-refresh}"
CONFIG="$STATE_DIR/config.env"
LOG="$STATE_DIR/refresh.log"
PID_FILE="$STATE_DIR/daemon.pid"
LOCK_FILE="$STATE_DIR/daemon.lock"
LAST_FILE="$STATE_DIR/last_slot"
WORK_DIR="$STATE_DIR/work"
BASHRC="$HOME/.bashrc"
MARK_BEGIN="# >>> $APP autostart >>>"
MARK_END="# <<< $APP autostart <<<"

# 中国自 1991 年起不再实行夏令时，Asia/Shanghai 恒为 UTC+8。
# 触发时间用 epoch 加固定偏移计算，不依赖本机时区，也不依赖 tzdata。
SH_OFFSET=$((8 * 3600))
SH_TZ="CST-8" # POSIX TZ 写法，只用于格式化显示，同样不需要 tzdata

# 默认配置，config.env 中的同名变量会覆盖它们
SLOTS="06:00 11:00 16:00"
MODEL="haiku"
PROMPT="Reply with exactly: ok"
PROXY_URL=""
CLAUDE_BIN=""
CATCHUP_SECONDS=1800    # 守护进程启动时，刚错过的时间点在这么久以内就立即补发
ALIGN_GRACE_SECONDS=900 # 消息落进了即将结束的旧窗口时，在这么久以内会等旧窗口结束再发一次
PROXY_RETRIES=15        # 触发时代理不通，每 60 秒重试一次，最多这么多次
SEND_RETRIES=3          # claude 调用失败时的重试次数
LOG_MAX_BYTES=1048576

OPT_PROXY=""
FOREGROUND=1
PROXY_MSG=""
CHECK_URL="https://www.google.com/generate_204"
LAST_RESET=""
LAST_STATUS=""

now() { date +%s; }

fmt() {
  TZ="$SH_TZ" date -d "@$1" '+%F %T' 2>/dev/null || TZ="$SH_TZ" date -r "$1" '+%F %T'
}

fmt_dur() {
  local s=$1
  [ "$s" -lt 0 ] && s=0
  if [ "$s" -lt 60 ]; then
    printf '%ds' "$s"
  else
    printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  fi
}

log() {
  local line
  line="[$(fmt "$(now)")] $*"
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$line" >>"$LOG"
  [ "$FOREGROUND" = 1 ] && printf '%s\n' "$line" >&2
  return 0
}

die() {
  printf '错误: %s\n' "$*" >&2
  exit 1
}

quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

load_config() {
  # shellcheck disable=SC1090
  [ -f "$CONFIG" ] && . "$CONFIG"
  local s
  for s in $SLOTS; do
    [[ "$s" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "SLOTS 里的时间点格式不对: $s (应为 HH:MM)"
  done
  [ -n "$SLOTS" ] || die "SLOTS 为空"
}

MANAGED_KEYS='SLOTS|MODEL|PROMPT|PROXY_URL|CLAUDE_BIN'

# 只改写脚本管理的几项，手动加的其他配置（如 SEND_RETRIES=5）原样保留
save_config() {
  mkdir -p "$STATE_DIR"
  local extra=""
  [ -f "$CONFIG" ] && extra="$(grep -v -E "^($MANAGED_KEYS)=|^# $APP 配置|^# 时间点为北京时间" "$CONFIG")"
  {
    echo "# $APP 配置，由脚本生成，可手动修改；守护进程每轮都会重新读取"
    echo "# 时间点为北京时间 (UTC+8)，空格分隔"
    echo "SLOTS=$(quote "$SLOTS")"
    echo "MODEL=$(quote "$MODEL")"
    echo "PROMPT=$(quote "$PROMPT")"
    echo "PROXY_URL=$(quote "$PROXY_URL")"
    echo "CLAUDE_BIN=$(quote "$CLAUDE_BIN")"
    if [ -n "$extra" ]; then printf '%s\n' "$extra"; fi
  } >"$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  chmod 600 "$CONFIG"
}

find_claude() {
  [ -n "$CLAUDE_BIN" ] && [ -x "$CLAUDE_BIN" ] && return 0
  CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
  if [ -z "$CLAUDE_BIN" ] && [ -x "$HOME/.local/bin/claude" ]; then
    CLAUDE_BIN="$HOME/.local/bin/claude"
  fi
  [ -n "$CLAUDE_BIN" ] || die "找不到 claude 命令，请先安装并登录 Claude Code"
  command -v curl >/dev/null || die "需要 curl"
}

# ---------- 时间点计算 ----------

# 输出昨天、今天、明天所有时间点的 epoch（北京时间的“天”）
slot_epochs() {
  local n=$1 local_now day d s h m
  local_now=$((n + SH_OFFSET))
  day=$((local_now - local_now % 86400 - SH_OFFSET))
  for d in -1 0 1; do
    for s in $SLOTS; do
      h=${s%%:*}
      m=${s##*:}
      echo $((day + d * 86400 + 10#$h * 3600 + 10#$m * 60))
    done
  done
}

prev_slot() {
  local n=$1 best=0 t
  for t in $(slot_epochs "$n"); do
    [ "$t" -le "$n" ] && [ "$t" -gt "$best" ] && best=$t
  done
  echo "$best"
}

next_slot() {
  local n=$1 best=0 t
  for t in $(slot_epochs "$n"); do
    [ "$t" -gt "$n" ] && { [ "$best" -eq 0 ] || [ "$t" -lt "$best" ]; } && best=$t
  done
  echo "$best"
}

# 分段睡眠：每段最多 60 秒并重新对时，系统时间被调整时也不会错过；
# 后台 sleep + wait 让 stop 能立即打断。fd 9 是守护进程锁，不传给子进程。
sleep_until() {
  local target=$1 left
  while :; do
    left=$((target - $(now)))
    [ "$left" -le 0 ] && return 0
    [ "$left" -gt 60 ] && left=60
    sleep "$left" 9>&- &
    wait $!
  done
}

# ---------- 代理 ----------

valid_proxy() {
  [ "$1" = direct ] || [[ "$1" =~ ^https?://[^[:space:]]+$ ]]
}

# 从代理地址里取出 host 和 port：去掉协议、账号密码和路径，IPv6 去掉方括号，缺省端口按协议补
proxy_host_port() {
  local hp=${1#*://} host port
  hp=${hp%%/*}
  hp=${hp##*@}
  if [[ "$hp" =~ ^\[([^]]+)\](:([0-9]+))?$ ]]; then
    host=${BASH_REMATCH[1]}
    port=${BASH_REMATCH[3]}
  else
    host=${hp%:*}
    port=${hp##*:}
    [ "$host" = "$hp" ] && port=""
  fi
  if [ -z "$port" ]; then
    case "$1" in https://*) port=443 ;; *) port=80 ;; esac
  fi
  echo "$host $port"
}

port_open() {
  local to=()
  command -v timeout >/dev/null && to=(timeout 3)
  ${to[@]+"${to[@]}"} bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$1" "$2" 2>/dev/null 9>&-
}

# 两步检查，都通过才算可用：1. 代理端口已开启；2. 经代理访问 Google 返回 2xx/3xx。
# direct 不走代理，跳过第 1 步直接访问 Google。检查结果的说明写进 PROXY_MSG。
proxy_ok() {
  local p=$1 host="" port="" err_file code err
  PROXY_MSG=""
  if [ "$p" != direct ]; then
    read -r host port <<<"$(proxy_host_port "$p")"
    if ! port_open "$host" "$port"; then
      PROXY_MSG="代理端口 $host:$port 未开启"
      return 1
    fi
  fi
  err_file="$(mktemp)"
  if [ "$p" = direct ]; then
    code=$(env -u HTTPS_PROXY -u https_proxy -u HTTP_PROXY -u http_proxy -u ALL_PROXY -u all_proxy \
      curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 10 --max-time 15 \
      "$CHECK_URL" 2>"$err_file" 9>&-)
  else
    code=$(env -u NO_PROXY -u no_proxy \
      curl -sS -o /dev/null -w '%{http_code}' --proxy "$p" --connect-timeout 10 --max-time 15 \
      "$CHECK_URL" 2>"$err_file" 9>&-)
  fi
  err="$(tr '\n' ' ' <"$err_file")"
  rm -f "$err_file"
  local via="直连"
  [ -n "$host" ] && via="代理端口 $host:$port 已开启，经代理"
  if [[ "$code" =~ ^[23] ]]; then
    PROXY_MSG="${via}访问 Google 成功 (HTTP $code)"
    return 0
  fi
  PROXY_MSG="${via}访问 Google 失败 (HTTP ${code:-000}${err:+, $err})"
  return 1
}

# 检测代理，不通时在终端里询问新的地址，直到连通或用户放弃
ensure_proxy() {
  local p
  p="${OPT_PROXY:-${PROXY_URL:-${HTTPS_PROXY:-${https_proxy:-${HTTP_PROXY:-${http_proxy:-}}}}}}"
  while :; do
    if [ -z "$p" ]; then
      echo "没有找到代理配置。" >&2
    elif ! valid_proxy "$p"; then
      echo "不支持的代理地址: $p（只支持 http:// 或 https://，或 direct 表示直连）" >&2
    elif proxy_ok "$p"; then
      PROXY_URL=$p
      echo "代理可用: $p（$PROXY_MSG）"
      return 0
    else
      echo "代理不可用: $p（$PROXY_MSG）" >&2
    fi
    if [ ! -t 0 ]; then
      echo "当前不是交互终端，无法询问。请用 --proxy 指定可用的代理后重试。" >&2
      return 1
    fi
    read -r -p "请输入代理地址（如 http://127.0.0.1:7890，direct 表示直连，直接回车放弃）: " p || p=""
    [ -n "$p" ] || {
      echo "已放弃，代理未确认连通。" >&2
      return 1
    }
  done
}

wait_proxy() {
  local i
  for ((i = 1; i <= PROXY_RETRIES; i++)); do
    if proxy_ok "$PROXY_URL"; then
      [ "$i" -gt 1 ] && log "代理已恢复"
      return 0
    fi
    log "代理不可用: $PROXY_URL（$PROXY_MSG），60 秒后重试 ($i/$PROXY_RETRIES)"
    sleep 60 9>&- &
    wait $!
  done
  return 1
}

# ---------- 发送消息 ----------

# 用干净的环境运行 claude：不继承调用方的会话变量，不加载用户设置、MCP、工具和斜杠命令，
# 也不保存会话记录，只发一句话给最便宜的模型。
run_claude() {
  local envs=(HOME="$HOME" PATH="$(dirname "$CLAUDE_BIN"):$PATH" LANG=C.UTF-8)
  [ -n "${USER:-}" ] && envs+=(USER="$USER")
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] && envs+=(CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR")
  if [ "$PROXY_URL" != direct ]; then
    envs+=(HTTPS_PROXY="$PROXY_URL" https_proxy="$PROXY_URL" HTTP_PROXY="$PROXY_URL" http_proxy="$PROXY_URL"
      NO_PROXY=localhost,127.0.0.1 no_proxy=localhost,127.0.0.1)
  fi
  local to=()
  command -v timeout >/dev/null && to=(timeout 180)
  mkdir -p "$WORK_DIR"
  (cd "$WORK_DIR" && env -i "${envs[@]}" ${to[@]+"${to[@]}"} "$CLAUDE_BIN" -p "$PROMPT" \
    --model "$MODEL" --tools "" --strict-mcp-config --setting-sources "" --disable-slash-commands \
    --no-session-persistence --max-turns 1 --output-format stream-json --verbose </dev/null 2>&1 9>&-)
}

# 发送一次（失败重试），成功后把 5h 窗口的重置时间和状态写进 LAST_RESET / LAST_STATUS
send_once() {
  local i out rc window
  LAST_RESET=""
  LAST_STATUS=""
  for ((i = 1; i <= SEND_RETRIES; i++)); do
    out="$(run_claude)"
    rc=$?
    if printf '%s\n' "$out" | grep '"type":"result"' | grep '"subtype":"success"' | grep -q '"is_error":false'; then
      window="$(printf '%s\n' "$out" | grep -o '"five_hour":{[^}]*}' | head -1)"
      # 旧版本没有 unifiedWindows 时，退回到 rateLimitType 为 five_hour 的那条
      [ -n "$window" ] || window="$(printf '%s\n' "$out" | grep '"rateLimitType":"five_hour"' | head -1)"
      LAST_RESET="$(printf '%s' "$window" | grep -o '"resetsAt":[0-9]*' | head -1 | cut -d: -f2)"
      LAST_STATUS="$(printf '%s' "$window" | grep -o '"status":"[a-z_]*"' | head -1 | cut -d'"' -f4)"
      return 0
    fi
    log "claude 调用失败 (exit $rc, 第 $i/$SEND_RETRIES 次): $(printf '%s' "$out" | tail -c 400 | tr '\n' ' ')"
    [ "$i" -lt "$SEND_RETRIES" ] && {
      sleep 60 9>&- &
      wait $!
    }
  done
  return 1
}

# 记录这次消息落在哪个窗口里。返回 2 表示落进了马上结束的旧窗口，需要等它结束后重发。
# resetsAt 是服务端取整过的时间，刚开的窗口和半小时内别人开的窗口无法区分，所以只如实记录起止时间。
report_window() {
  local left
  if [ -z "$LAST_RESET" ]; then
    log "已发送，但输出里没有 5h 窗口信息，无法确认窗口时间"
    return 0
  fi
  left=$((LAST_RESET - $(now)))
  [ "$LAST_STATUS" = rejected ] && log "注意: 5h 额度已用尽 (status=rejected)"
  if [ "$left" -le "$ALIGN_GRACE_SECONDS" ]; then
    log "消息落进了即将结束的旧窗口（$(fmt "$LAST_RESET") 结束，还剩 $(fmt_dur "$left")）"
    return 2
  fi
  log "当前 5h 窗口: $(fmt $((LAST_RESET - 5 * 3600))) ~ $(fmt "$LAST_RESET")（还剩 $(fmt_dur "$left")）"
  return 0
}

trigger() {
  local label=$1
  log "==== 触发: $label ===="
  wait_proxy || {
    log "代理持续不通，放弃本次触发"
    return 1
  }
  send_once || {
    log "多次发送失败，放弃本次触发"
    return 1
  }
  report_window
  [ $? -eq 2 ] || return 0
  log "等旧窗口结束后重发一次"
  sleep_until $((LAST_RESET + 30))
  wait_proxy && send_once || {
    log "重发失败"
    return 1
  }
  report_window
  return 0
}

trim_log() {
  local size
  size=$(wc -c <"$LOG" 2>/dev/null || echo 0)
  if [ "$size" -gt "$LOG_MAX_BYTES" ]; then
    tail -n 3000 "$LOG" >"$LOG.tmp" && mv "$LOG.tmp" "$LOG"
  fi
}

# ---------- 守护进程 ----------

running() {
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null)" || return 1
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  # 防止 pid 被别的进程复用
  if [ -r "/proc/$pid/cmdline" ]; then
    tr '\0' ' ' <"/proc/$pid/cmdline" | grep -q "$APP.* _daemon" || return 1
  fi
  return 0
}

daemon_main() {
  FOREGROUND=0
  mkdir -p "$STATE_DIR" "$WORK_DIR"
  if command -v flock >/dev/null; then
    exec 9>"$LOCK_FILE"
    flock -n 9 || exit 0
  fi
  echo $$ >"$PID_FILE"
  trap 'log "守护进程退出 (pid $$)"; rm -f "$PID_FILE"; exit 0' TERM INT HUP
  load_config
  find_claude
  valid_proxy "$PROXY_URL" || {
    log "配置里没有有效的代理 (PROXY_URL=$PROXY_URL)，请先运行: $SELF start"
    rm -f "$PID_FILE"
    exit 1
  }
  log "守护进程启动 (pid $$)，北京时间触发点: $SLOTS，模型: $MODEL，代理: $PROXY_URL"
  if proxy_ok "$PROXY_URL"; then
    log "代理可用: $PROXY_URL（$PROXY_MSG）"
  else
    log "警告: 代理当前不可用: $PROXY_URL（$PROXY_MSG），触发时会再重试"
  fi
  local now_ts prev next last
  while :; do
    load_config
    now_ts=$(now)
    prev=$(prev_slot "$now_ts")
    next=$(next_slot "$now_ts")
    last="$(cat "$LAST_FILE" 2>/dev/null)"
    [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [ "$prev" -gt "$last" ] && [ $((now_ts - prev)) -le "$CATCHUP_SECONDS" ]; then
      echo "$prev" >"$LAST_FILE"
      trigger "$(fmt "$prev")"
      trim_log
      continue
    fi
    log "下次触发: $(fmt "$next")"
    sleep_until "$next"
  done
}

start_daemon() {
  local quiet=${1:-}
  mkdir -p "$STATE_DIR" "$WORK_DIR"
  if running; then
    [ -n "$quiet" ] || echo "守护进程已在运行 (pid $(cat "$PID_FILE"))"
    return 0
  fi
  local envs=(HOME="$HOME" PATH="$PATH" LANG=C.UTF-8)
  [ -n "${USER:-}" ] && envs+=(USER="$USER")
  [ -n "${CLAUDE_CONFIG_DIR:-}" ] && envs+=(CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR")
  [ -n "${CLAUDE_5H_HOME:-}" ] && envs+=(CLAUDE_5H_HOME="$CLAUDE_5H_HOME")
  local launcher=(nohup)
  command -v setsid >/dev/null && launcher=(setsid nohup)
  env -i "${envs[@]}" "${launcher[@]}" bash "$SELF" _daemon >>"$LOG" 2>&1 </dev/null &
  [ -n "$quiet" ] && return 0
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    running && {
      echo "守护进程已启动 (pid $(cat "$PID_FILE"))"
      return 0
    }
    sleep 0.5
  done
  die "守护进程启动失败，查看日志: $LOG"
}

stop_daemon() {
  local pid i
  if ! running; then
    echo "守护进程未运行"
    rm -f "$PID_FILE"
    return 0
  fi
  pid="$(cat "$PID_FILE")"
  kill -TERM "$pid" 2>/dev/null
  for ((i = 0; i < 20; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.5
  done
  kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  rm -f "$PID_FILE"
  echo "守护进程已停止 (pid $pid)"
}

show_status() {
  local n next
  n=$(now)
  next=$(next_slot "$n")
  if running; then
    echo "状态:       运行中 (pid $(cat "$PID_FILE"))"
  else
    echo "状态:       未运行"
  fi
  echo "触发时间:   $SLOTS（北京时间，每天）"
  echo "下次触发:   $(fmt "$next")（还有 $(fmt_dur $((next - n)))）"
  echo "当前北京时间: $(fmt "$n")"
  echo "模型:       $MODEL"
  echo "代理:       ${PROXY_URL:-未配置}"
  echo "claude:     ${CLAUDE_BIN:-未找到}"
  echo "开机自启:   $(grep -qF "$MARK_BEGIN" "$BASHRC" 2>/dev/null && echo "已加入 $BASHRC" || echo "未启用")"
  echo "日志:       $LOG"
  if [ -f "$LOG" ]; then
    echo "--- 最近日志 ---"
    tail -n 8 "$LOG"
  fi
}

enable_autostart() {
  if grep -qF "$MARK_BEGIN" "$BASHRC" 2>/dev/null; then
    echo "自启已存在于 $BASHRC"
    return 0
  fi
  {
    echo ""
    echo "$MARK_BEGIN"
    echo "[ -x $(quote "$SELF") ] && $(quote "$SELF") ensure >/dev/null 2>&1"
    echo "$MARK_END"
  } >>"$BASHRC"
  echo "已在 $BASHRC 末尾加入自启（每次打开交互 shell 时，如果守护进程没在运行就静默拉起）"
}

disable_autostart() {
  grep -qF "$MARK_BEGIN" "$BASHRC" 2>/dev/null || {
    echo "$BASHRC 中没有自启配置"
    return 0
  }
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '$0==b{skip=1;next} $0==e{skip=0;next} !skip' "$BASHRC" >"$BASHRC.$APP.tmp" &&
    cat "$BASHRC.$APP.tmp" >"$BASHRC" && rm -f "$BASHRC.$APP.tmp"
  echo "已从 $BASHRC 移除自启"
}

parse_opts() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --proxy)
        [ $# -ge 2 ] || die "--proxy 需要参数"
        OPT_PROXY=$2
        shift 2
        ;;
      --proxy=*)
        OPT_PROXY=${1#--proxy=}
        shift
        ;;
      *) die "未知参数: $1" ;;
    esac
  done
}

main() {
  local cmd=${1:-}
  [ $# -gt 0 ] && shift
  case "$cmd" in
    _daemon) daemon_main ;;
    start | restart)
      parse_opts "$@"
      load_config
      find_claude
      ensure_proxy || exit 1
      save_config
      [ "$cmd" = restart ] && stop_daemon
      start_daemon
      echo
      show_status
      ;;
    stop) stop_daemon ;;
    status)
      load_config
      show_status
      ;;
    test)
      parse_opts "$@"
      load_config
      find_claude
      ensure_proxy || exit 1
      save_config
      trigger "手动测试"
      ;;
    check-proxy)
      parse_opts "$@"
      load_config
      ensure_proxy || exit 1
      save_config
      ;;
    logs) tail -n "${1:-50}" "$LOG" 2>/dev/null || echo "暂无日志" ;;
    ensure)
      # 只在已经配置过（代理确认连通过）时才自启，避免在 .bashrc 里卡住或弹出询问
      [ -f "$CONFIG" ] || exit 0
      load_config
      start_daemon quiet
      ;;
    enable-autostart) enable_autostart ;;
    disable-autostart) disable_autostart ;;
    *)
      sed -n '2,/^$/p' "$SELF" | sed 's/^# \{0,1\}//'
      [ -z "$cmd" ] || [ "$cmd" = help ] || [ "$cmd" = -h ] || [ "$cmd" = --help ] || exit 1
      ;;
  esac
}

# 允许 source 进来单独测试函数
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
