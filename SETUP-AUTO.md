# 一键自动配置（Windows / Linux / macOS）

把 **WorkBuddy 的模型**经本地桥暴露给 API 客户端 / cc-haha。克隆仓库后跑一条命令，
脚本会：检查 Node → 装依赖 → 生成 `.env` → 启动桥 → 打印设备登录链接并等待登录
→（可选）把 cc-haha 切到桥 → 自检（让模型回「通了」）。

所有脚本都是**幂等**的，可以反复运行。已有配置只补缺、不覆盖。

---

## 一键命令

### Windows（PowerShell）

```powershell
git clone https://github.com/jonjlhuang-blip/workbuddy-to-dsh.git
cd workbuddy-to-dsh
powershell -ExecutionPolicy Bypass -File .\setup\setup.ps1
```

需要 Node.js 20+。没装时脚本会提示；可用：

```powershell
winget install OpenJS.NodeJS.LTS
```

> Windows PowerShell 5.1 默认禁止执行脚本，所以用 `-ExecutionPolicy Bypass -File`，
> 只对这一次运行生效，不改系统策略。PowerShell 7（`pwsh`）同样适用。

### Linux / macOS（bash）

```bash
git clone https://github.com/jonjlhuang-blip/workbuddy-to-dsh.git
cd workbuddy-to-dsh
bash setup/setup.sh
```

---

## 常用选项（两端一致）

| 选项 | 作用 |
|---|---|
| `--cchh` | 备份并配置 cc-haha：默认 provider 走本地桥，模型 `deepseek-v4.1-flash` |
| `--autostart` | 注册开机自启：Windows 计划任务（登录时）/ Linux `systemd --user` / macOS LaunchAgent |
| `--no-login` | 跳过设备登录（已有桌面端凭据，或之前登录过） |
| `--dry-run` | 只演练：不安装、不启动、不登录、不改任何配置 |
| `--skip-selftest` | 跳过最后的 chat 自检 |
| `--port 8795` | 首选端口（默认 8793，被占用自动顺延） |
| `--model <name>` | 自检与 cc-haha 使用的模型（默认 `deepseek-v4.1-flash`） |

示例：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup\setup.ps1 --cchh --autostart
```

```bash
bash setup/setup.sh --cchh --autostart
```

---

## 过程记录

### 1. 检查 Node.js
要求 **Node >= 20**（用到内建 `fetch`、全局 `AbortSignal`）。
- Windows：依次尝试 `where node`、`%ProgramFiles%\nodejs\node.exe`、
  `%LOCALAPPDATA%\Programs\nodejs\node.exe`。
- Linux/macOS：用 `PATH` 里的 `node`，版本不够会直接退出（退出码 5）。

### 2. 选端口，写 `.env`
`.env` 里写三项（只补缺失键，**不覆盖**已有值）：

```env
WORKBUDDY_HOST=127.0.0.1
WORKBUDDY_PORT=8793
WORKBUDDY_ANTHROPIC_MODEL=deepseek-v4.1-flash
```

端口规则：
- 不传 `--port` 时，**沿用 `.env` 里已有的 `WORKBUDDY_PORT`**（重跑不漂移），没有才是 8793。
- 端口上已经是**本桥** → 复用，不另起一个（通过 `/health` 的 `build` 字段识别）。
- 被**其它程序**占用 → `setup.sh` 自动顺延到下一个空闲端口并写进 `.env`；
  `setup.ps1` 不擅自改 `.env`，会报错提示用 `--port` 重跑。
- 当前 shell 里若有残留的 `WORKBUDDY_PORT`，它优先级高于 `.env`，脚本会提示，
  并以 `.env`/本次解析出的端口为准启动。

### 3. `npm install`
只在 `node_modules` 不存在时执行。

### 4. 本地令牌
桥用一把本机回环令牌（`~/.workbuddy-bridge/bridge-token`，权限 0600）阻止同机其它
程序误用。脚本只会打印**路径**，**永远不打印令牌值**。首次运行自动生成。

### 5. 启动桥（后台）
`node bridge/launch.mjs`：
- Windows：`Start-Process` 隐藏窗口，stdout/stderr 写
  `%USERPROFILE%\.workbuddy-bridge\logs\bridge.log`，PID 写 `bridge.pid`。
- Linux/macOS：`nohup` 式后台运行，日志 `~/.workbuddy-bridge/logs/bridge.log`。

### 6. 设备登录
`POST /v1/auth/device` 拿到登录链接并打印；浏览器打开完成登录后脚本自动检测到
并继续。**链接有效期 10 分钟**。

已有桌面端登录（WorkBuddy 客户端）时，桥可能无需重新登录即可用；此时轮询会很快
返回已登录。

### 7. 可选：cc-haha（`--cchh`）
改动两处，都**先备份**为 `*.bak-<时间戳>`：

| 文件 | 改动 |
|---|---|
| `~/.claude/cc-haha/providers.json` | 新增/更新自定义 provider `workbuddy-bridge`，设为 `activeId`；`baseUrl=http://127.0.0.1:<端口>`，`apiFormat=anthropic`，四档模型都是目标模型，`apiKey` **留空** |
| `~/.claude/cc-haha/settings.json` | `model` 与 `ANTHROPIC_{,DEFAULT_HAIKU_,DEFAULT_SONNET_,DEFAULT_OPUS_}MODEL` 改为目标模型；`CC_HAHA_GROK_OAUTH_PROVIDER=0`（否则 Grok OAuth 会抢聊天请求）；补上下文窗口 300000 |

`CLAUDE_CONFIG_DIR` 存在时配置目录取 `$CLAUDE_CONFIG_DIR/cc-haha`。

**令牌以文件/环境变量方式读取，不写进配置。** cc-haha 会把 provider 的 `apiKey`
原样抄进环境变量，不展开文件路径或 `$VAR`，所以 `apiKey` 留空，启动 cc-haha 时注入：

```bash
# bash
export ANTHROPIC_AUTH_TOKEN="$(cat "$HOME/.workbuddy-bridge/bridge-token")"
```

```powershell
# PowerShell
$env:ANTHROPIC_AUTH_TOKEN = (Get-Content -Raw "$HOME\.workbuddy-bridge\bridge-token").Trim()
```

如果你有自己的启动器脚本（例如 `~/.local/bin/claude-haha`），让它从同一个令牌文件
注入即可；脚本不会去改它。

### 8. 可选：开机自启（`--autostart`）
- **Windows**：计划任务 `WorkBuddyBridge`，登录时运行 `node bridge\launch.mjs`。
  查看：`Get-ScheduledTask -TaskName WorkBuddyBridge`；
  删除：`Unregister-ScheduledTask -TaskName WorkBuddyBridge -Confirm:$false`。
- **Linux**：`~/.config/systemd/user/workbuddy-bridge.service`，并
  `systemctl --user enable --now workbuddy-bridge`。无用户会话（容器等）时会写文件
  但提示手动启用。
- **macOS**：`~/Library/LaunchAgents/com.workbuddy.bridge.plist`。

### 9. 自检
发一条 `POST /v1/chat/completions`（`max_tokens` 很小），断言回复包含「通了」。
- `--no-login` 时先尝试真聊；不行则只校验端口可应答（会明确说明「未验证对话」）。
- 自检失败退出码 4。

退出码：`0` 成功 / `1` 一般失败 / `3` 登录链接过期 / `4` 自检失败 / `5` 环境问题。

---

## 回滚

脚本只做这些可逆改动：

| 改动 | 回滚 |
|---|---|
| `.env` 新增的键 | 编辑或删除 `.env`（已被 git 忽略） |
| cc-haha `providers.json` / `settings.json` | 用同目录 `*.bak-<时间戳>` 还原（`--cchh` 时生成） |
| Windows 计划任务 | `Unregister-ScheduledTask -TaskName WorkBuddyBridge -Confirm:$false` |
| Linux systemd | `systemctl --user disable --now workbuddy-bridge`，再删 `~/.config/systemd/user/workbuddy-bridge.service` |
| macOS LaunchAgent | `launchctl unload ~/Library/LaunchAgents/com.workbuddy.bridge.plist`，再删该 plist |
| 后台桥进程 | Windows：`Stop-Process -Id (Get-Content "$HOME\.workbuddy-bridge\bridge.pid")`；Linux/macOS：`kill "$(cat ~/.workbuddy-bridge/bridge.pid)"` |
| 令牌文件 | 删除 `~/.workbuddy-bridge/bridge-token`，下次启动会重新生成（旧客户端需换新值） |

整份 cc-haha 还原示例（bash）：

```bash
cd ~/.claude/cc-haha
ls *.bak-*           # 找到本次的时间戳
cp -a providers.json.bak-<时间戳> providers.json
cp -a settings.json.bak-<时间戳> settings.json
```

> 注意：`*.bak-*` 已被 `.gitignore` 覆盖，不会误提交。

---

## 常见问题

### 端口被占用
- `setup.sh` 会自动换到下一个空闲端口，并写进 `.env`。
- `setup.ps1` 不会擅自改 `.env`（避免把 cc-haha 指向错误端口），会报
  「Port N is held by another program」。这时用 `--port 8795` 重跑即可。
- 想手动指定：编辑 `.env` 的 `WORKBUDDY_PORT`，或 `--port <n>`。

### 设备链接 10 分钟过期
登录链接 10 分钟内有效。过期后重新运行 setup（脚本幂等，会复用已有配置并签发新链接）：

```powershell
powershell -ExecutionPolicy Bypass -File .\setup\setup.ps1
```

```bash
bash setup/setup.sh
```

### 自检失败（没有「通了」）
1. 确认已登录：浏览器打开控制台 `http://127.0.0.1:8792`，或看桥日志
   `~/.workbuddy-bridge/logs/bridge.log`。
2. 令牌不一致？重启桥后再测（令牌文件和控制台必须指向同一个）。
3. 用与桥相同的端口重跑：`bash setup/setup.sh --skip-selftest` 后再单独排障。

### Node 版本过低
需要 Node 20+。`node -v` 查看；Windows 用 `winget install OpenJS.NodeJS.LTS`，
macOS 用 `brew install node`。

### 我的令牌在哪
`~/.workbuddy-bridge/bridge-token`（或 `WORKBUDDY_LOCAL_TOKEN` 环境变量）。
**不要把内容贴进聊天、Issue 或提交。** 控制台「客户端接入」页也能看到。

### 我用了代理，cc-haha 还是走原来的模型
检查 `~/.claude/cc-haha/providers.json` 的 `activeId` 是否为 `workbuddy-bridge`，
并确认启动 cc-haha 时 `ANTHROPIC_AUTH_TOKEN` 已从令牌文件注入。

---

## 安全说明（提交前的扫描）

下列内容**永不入库**，`.gitignore` 已覆盖：

- `.env`
- `bridge-token` / `*.info`（登录凭据）/ `*.bak-*`
- `*.log`、`node_modules/`

提交前会执行 secret 扫描（`git grep` 检查常见令牌形态）。脚本只打印令牌**路径**，
从不打印令牌值。
