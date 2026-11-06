#!/usr/bin/env bash
# ============================================================================
#  WorkBuddy → API Bridge 一键配置（Linux / macOS）
#
#  用法：
#    bash setup/setup.sh                 # 安装依赖、写 .env、启动桥、设备登录、自检
#    bash setup/setup.sh --cchh          # 另外把 cc-haha 默认切到 bridge
#    bash setup/setup.sh --autostart     # 注册开机自启（Linux: systemd --user / macOS: LaunchAgent）
#    bash setup/setup.sh --no-login      # 跳过设备登录（已有桌面端凭据或已登录过）
#    bash setup/setup.sh --dry-run       # 只演练：不安装、不启动、不登录、不改配置
#    bash setup/setup.sh --port 8795 --model deepseek-v4.1-flash
#    bash setup/setup.sh --skip-selftest # 跳过最后的 chat 自检
#
#  脚本是幂等的：可以反复运行。已存在的 .env 只补缺失的键，不会覆盖；
#  桥已经在跑就不重复拉起；已登录就跳过登录步骤。
#
#  退出码：0 成功 / 1 一般失败 / 3 登录链接过期 / 4 自检失败 / 5 环境不满足
# ============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/setup/lib/setup-helper.mjs"
cd "$ROOT"

PORT=""
MODEL="deepseek-v4.1-flash"
DO_CCHH=0
AUTOSTART=0
NO_LOGIN=0
DRY_RUN=0
SKIP_SELFTEST=0
TAG="workbuddy-bridge"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cchh) DO_CCHH=1 ;;
    --autostart) AUTOSTART=1 ;;
    --no-login) NO_LOGIN=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --skip-selftest) SKIP_SELFTEST=1 ;;
    --port) PORT="${2:?--port 需要参数}"; shift ;;
    --port=*) PORT="${1#*=}" ;;
    --model) MODEL="${2:?--model 需要参数}"; shift ;;
    --model=*) MODEL="${1#*=}" ;;
    -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "[x] 未知参数：$1（--help 查看用法）" >&2; exit 5 ;;
  esac
  shift
done

# 未显式给 --port 时沿用 .env 里已有的 WORKBUDDY_PORT（重跑不漂移），否则用默认 8793。
if [[ -z "$PORT" ]]; then
  PORT="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\+\)\?WORKBUDDY_PORT=//p' .env 2>/dev/null | tail -n 1 | tr -d '\r' )"
  PORT="${PORT:-8793}"
fi
case "$PORT" in
  ''|*[!0-9]*) die "端口必须是数字：$PORT" 5 ;;
esac
if ! [[ "$PORT" -ge 1 && "$PORT" -le 65535 ]]; then die "端口超出范围：$PORT" 5; fi

info() { printf '\n==> %s\n' "$*"; }
warn() { printf '[!] %s\n' "$*" >&2; }
die() { printf '[x] %s\n' "$*" >&2; exit "${2:-1}"; }
dry() { [[ $DRY_RUN -eq 1 ]] && printf '    [dry-run] %s\n' "$*"; return 0; }

nodeh() { node "$HELPER" "$@"; }

# ---------------------------------------------------------------------------
# 1. 检查 Node.js
# ---------------------------------------------------------------------------
info "检查 Node.js（需要 >= 20）"
if ! command -v node >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[x] 未找到 node。
    请安装 Node.js 20 或更高版本，然后重新运行：
      Linux:  https://nodejs.org/  或  (Debian/Ubuntu)  sudo apt install nodejs npm
      macOS:  brew install node    或  https://nodejs.org/
EOF
  exit 5
fi
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]')"
if [[ "$NODE_MAJOR" -lt 20 ]]; then
  die "Node.js 版本过低：$(node -v)。本项目需要 Node >= 20，请升级后再运行。" 5
fi
nodeh noop || die "Node 运行环境检查失败" 5
command -v npm >/dev/null 2>&1 || die "找到 node 但未找到 npm。请安装完整的 Node.js（含 npm）。" 5
echo "    Node $(node -v) / npm $(npm -v)"

# ---------------------------------------------------------------------------
# 2. 选端口
# ---------------------------------------------------------------------------
# 进程环境变量优先级高于 .env（config.mjs），残留的旧值会静默压过刚写的配置。
# setup 以 .env 为准：发现不一致就提示，并在启动桥时显式覆盖成当前端口。
if [[ -n "${WORKBUDDY_PORT:-}" && "$WORKBUDDY_PORT" != "$PORT" ]]; then
  warn "当前 shell 里的 WORKBUDDY_PORT=$WORKBUDDY_PORT 会压过 .env；本次按 $PORT 运行（用 unset WORKBUDDY_PORT 消除提示）"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  echo "    [dry-run] 端口保持 $PORT（已运行本桥则复用；被其它程序占用则自动顺延）"
else
  info "选择桥端口（默认 $PORT）"
  # 这个端口上已经是本桥（重跑的常见情况）→ 复用它，绝不顺延到空端口。
  if nodeh is-bridge "$PORT"; then
    echo "    端口 $PORT 上已是本桥，复用"
  elif nodeh port "$PORT" >/dev/null 2>&1; then
    echo "    端口 $PORT 空闲"
  else
    warn "端口 $PORT 被其它程序占用，自动顺延"
    PORT="$(nodeh pick-port "$PORT")" || die "没有可用端口"
  fi
  echo "    桥端口：$PORT"
fi

# ---------------------------------------------------------------------------
# 3. 写 .env（幂等：只补缺失键）
# ---------------------------------------------------------------------------
info "准备 .env（含本机配置，已被 .gitignore 忽略；不会包含任何上游凭据）"
write_env() {
  local file="$ROOT/.env"
  [[ -f "$file" ]] || { printf '# 由 setup/setup.sh 生成。本文件已被 .gitignore 忽略。\n' > "$file"; }
  local key="$1" value="$2"
  if grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=" "$file"; then
    echo "    .env 已有 $key，保持不变" >&2
  else
    printf '%s=%s\n' "$key" "$value" >> "$file"
    echo "    .env 写入 $key=$value" >&2
  fi
}
if [[ $DRY_RUN -eq 1 ]]; then
  dry "确保 .env 中 WORKBUDDY_HOST=127.0.0.1 / WORKBUDDY_PORT=$PORT / WORKBUDDY_ANTHROPIC_MODEL=$MODEL"
else
  write_env WORKBUDDY_HOST 127.0.0.1
  write_env WORKBUDDY_PORT "$PORT"
  write_env WORKBUDDY_ANTHROPIC_MODEL "$MODEL"
fi

# ---------------------------------------------------------------------------
# 4. npm install
# ---------------------------------------------------------------------------
info "安装依赖（npm install）"
if [[ -d "$ROOT/node_modules" ]] && [[ $DRY_RUN -eq 0 ]]; then
  echo "    node_modules 已存在，跳过（如需重装请先删除该目录）"
elif [[ $DRY_RUN -eq 1 ]]; then
  dry "npm install --no-audit --no-fund"
else
  npm install --no-audit --no-fund || die "npm install 失败"
fi

# 路径解析统一交给 Node（与 config.mjs 的默认值一致）
nodeh ensure-token >/dev/null || die "准备本地令牌失败"
TOKEN_FILE="$(nodeh ensure-token)"
if [[ "$TOKEN_FILE" == env:* ]]; then
  echo "    本地令牌：来自环境变量 WORKBUDDY_LOCAL_TOKEN"
else
  chmod 600 "$TOKEN_FILE" 2>/dev/null || true
  echo "    本地令牌文件：$TOKEN_FILE（0600，不打印内容）"
fi

# ---------------------------------------------------------------------------
# 5. 启动桥（后台）
# ---------------------------------------------------------------------------
info "启动桥服务"
LOG_DIR="$HOME/.workbuddy-bridge/logs"
BRIDGE_LOG="$LOG_DIR/bridge.log"
bridge_pid_file() { echo "$HOME/.workbuddy-bridge/bridge.pid"; }
[[ $DRY_RUN -eq 1 ]] || mkdir -p "$LOG_DIR"

if [[ $DRY_RUN -eq 1 ]]; then
  dry "node bridge/launch.mjs >> $BRIDGE_LOG 2>&1 &"
elif nodeh port "$PORT" >/dev/null 2>&1; then
  # 端口空闲 → 没在跑；启动一个新的。
  # 注意变量名是 WORKBUDDY_PORT（config.mjs 读的就是它）；写成 PORT 桥会回到默认端口。
  WORKBUDDY_PORT="$PORT" WORKBUDDY_HOST=127.0.0.1 \
    node bridge/launch.mjs >>"$BRIDGE_LOG" 2>&1 &
  echo $! > "$(bridge_pid_file)"
  # 等待真正 listen：桥先 listen 再读凭据，/health 有应答（含 401）即说明端口起来了。
  for _ in $(seq 1 40); do
    nodeh is-bridge "$PORT" && break
    kill -0 "$(cat "$(bridge_pid_file)")" 2>/dev/null || break
    sleep 0.5
  done
  if ! nodeh is-bridge "$PORT"; then
    warn "桥没有在 $PORT 上起来。日志末尾："
    tail -n 8 "$BRIDGE_LOG" >&2 || true
    die "启动桥失败" 4
  fi
  echo "    已启动，PID $(cat "$(bridge_pid_file)")，日志 $BRIDGE_LOG"
elif nodeh is-bridge "$PORT"; then
  echo "    $PORT 上的本桥已在运行，跳过启动"
else
  die "端口 $PORT 被另一个程序占用（不是本桥）。请用 --port <其它端口> 重跑，或先腾出该端口。" 5
fi

# ---------------------------------------------------------------------------
# 6. 设备登录
# ---------------------------------------------------------------------------
B="127.0.0.1"
if [[ $NO_LOGIN -eq 1 ]]; then
  info "跳过设备登录（--no-login）"
elif [[ $DRY_RUN -eq 1 ]]; then
  info "设备登录（演练模式不真正发起）"
  dry "node $HELPER login $B $PORT"
else
  info "设备登录：下面会打印登录链接，在浏览器中打开并完成登录"
  # 已有的桌面端凭据会让轮询直接 ready；否则等用户点链接。
  rc=0
  nodeh login 127.0.0.1 "$PORT" || rc=$?
  if [[ $rc -ne 0 ]]; then
    die "设备登录未完成（退出码 $rc）。稍后可重新运行本脚本，登录链接 10 分钟内有效。" "$rc"
  fi
fi

# ---------------------------------------------------------------------------
# 7. 可选：cc-haha
# ---------------------------------------------------------------------------
CCHH_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/cc-haha"
PROVIDERS="$CCHH_DIR/providers.json"
SETTINGS="$CCHH_DIR/settings.json"
STAMP="$(date +%Y%m%d-%H%M%S)"

if [[ $DO_CCHH -eq 1 ]]; then
  info "配置 cc-haha（默认走本地桥，模型 $MODEL）"
  echo "    配置目录：$CCHH_DIR"
  old_provider="$(node -e 'try{const fs=require("node:fs");console.log(JSON.parse(fs.readFileSync(process.argv[1],"utf8").replace(/^\uFEFF/,"")).activeId||"")}catch{}' "$PROVIDERS" 2>/dev/null || true)"
  echo "    原 activeId：${old_provider:-（无配置文件）}，新 activeId：workbuddy-bridge"
  echo "    令牌不进配置文件：cc-haha 启动时从令牌文件读取（见 SETUP-AUTO.md 的说明）"
  if [[ $DRY_RUN -eq 1 ]]; then
    dry "备份 $SETTINGS / $PROVIDERS → *.bak-$STAMP"
    dry "providers.json：设置 activeId=workbuddy-bridge，baseUrl=http://127.0.0.1:$PORT，apiKey 留空"
    dry "settings.json：model 与 ANTHROPIC_MODEL* = $MODEL，CC_HAHA_GROK_OAUTH_PROVIDER=0"
  else
    mkdir -p "$CCHH_DIR"
    # 备份在 cchh-config.mjs 里做（同一 stamp 已备份则跳过，保持幂等）。
    node "$ROOT/setup/lib/cchh-config.mjs" --dir "$CCHH_DIR" --port "$PORT" --model "$MODEL" --stamp "$STAMP"
    cat <<EOF

    cc-haha 还需要在启动时注入令牌。二选一：
      a) 启动 cc-haha 的 shell 里 export ANTHROPIC_AUTH_TOKEN="\$(cat "$TOKEN_FILE")"
      b) 若你用自带启动器脚本（如 ~/.local/bin/claude-haha），让它从同一文件注入。
    详细说明见 SETUP-AUTO.md「cc-haha」一节。
EOF
  fi
else
  info "未启用 cc-haha 配置（需要时加 --cchh）"
fi

# ---------------------------------------------------------------------------
# 8. 可选：开机自启
# ---------------------------------------------------------------------------
if [[ $AUTOSTART -eq 1 ]]; then
  info "注册开机自启"
  if [[ $DRY_RUN -eq 1 ]]; then
    dry "注册 systemd --user（Linux）或 LaunchAgent（macOS）"
  elif [[ "$(uname -s)" == "Linux" ]]; then
    UNIT_DIR="$HOME/.config/systemd/user"
    UNIT="$UNIT_DIR/workbuddy-bridge.service"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT" <<EOF
[Unit]
Description=WorkBuddy local bridge
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$ROOT
ExecStart=$(command -v node) $ROOT/bridge/launch.mjs
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
EOF
    if command -v systemctl >/dev/null 2>&1 \
      && systemctl --user daemon-reload >/dev/null 2>&1 \
      && systemctl --user enable workbuddy-bridge.service >/dev/null 2>&1; then
      systemctl --user start workbuddy-bridge.service || warn "服务已启用但启动失败，可查看 journalctl --user -u workbuddy-bridge"
      echo "    已注册并启用：$UNIT"
    else
      warn "systemctl --user 不可用（容器/无用户会话常见）。unit 已写到 $UNIT，登录图形会话后执行：systemctl --user enable --now workbuddy-bridge"
    fi
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    PLIST="$HOME/Library/LaunchAgents/com.workbuddy.bridge.plist"
    LOG_DIR="$HOME/.workbuddy-bridge/logs"
    mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
    cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.workbuddy.bridge</string>
  <key>ProgramArguments</key><array>
    <string>$(command -v node)</string>
    <string>$ROOT/bridge/launch.mjs</string>
  </array>
  <key>WorkingDirectory</key><string>$ROOT</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$LOG_DIR/bridge.log</string>
  <key>StandardErrorPath</key><string>$LOG_DIR/bridge.log</string>
</dict></plist>
EOF
    launchctl unload "$PLIST" 2>/dev/null || true
    if launchctl load "$PLIST"; then
      echo "    已注册：$PLIST"
    else
      warn "launchctl load 失败，plist 已写出：$PLIST"
    fi
  else
    warn "未知系统 $(uname -s)，跳过自启注册"
  fi
else
  echo
  echo "    提示：需要开机自启请加 --autostart"
fi

# ---------------------------------------------------------------------------
# 9. 自检
# ---------------------------------------------------------------------------
if [[ $SKIP_SELFTEST -eq 1 ]]; then
  info "跳过自检（--skip-selftest）"
elif [[ $DRY_RUN -eq 1 ]]; then
  info "自检（演练模式不真正发起 chat）"
  dry "POST http://127.0.0.1:$PORT/v1/chat/completions，断言回复包含「通了」"
elif [[ $NO_LOGIN -eq 1 ]]; then
  # 没有新登录不代表没登录过：能聊就真聊一次，不能聊只校验端口。
  if nodeh chat 127.0.0.1 "$PORT"; then
    :
  else
    warn "chat 自检未通过（--no-login：可能尚未登录，或模型暂不可用）。请去掉 --no-login 重跑完成登录。"
    if nodeh port "$PORT" >/dev/null 2>&1; then
      die "桥端口 $PORT 上没有服务应答" 4
    fi
    echo "    桥在 $PORT 上可应答（未验证对话）"
  fi
else
  info "自检：发一条 chat 请求，期望回复「通了」"
  nodeh chat 127.0.0.1 "$PORT" || die "chat 自检失败（详见上方输出）" 4
fi

info "完成"
cat <<EOF
  桥地址    http://127.0.0.1:$PORT/v1
  模型      $MODEL
  令牌文件  $TOKEN_FILE（不要把内容贴进聊天或提交）
  日志      $BRIDGE_LOG
  停止桥    kill \$(cat "$(bridge_pid_file)" 2>/dev/null)   # 或 pkill -f bridge/launch.mjs
EOF
