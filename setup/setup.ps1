<#
  WorkBuddy -> API Bridge one-command setup (Windows).

  IMPORTANT: this file is intentionally pure ASCII. Windows PowerShell 5.1 reads
  .ps1 files as ANSI unless they have a UTF-8 BOM; non-ASCII text would be
  mangled. All user-facing Chinese messages come from the Node helper
  (setup/lib/setup-helper.mjs), and the script itself writes its small
  .env / scheduled-task text in English.

  Usage (from the repository root, in PowerShell):
    powershell -ExecutionPolicy Bypass -File .\setup\setup.ps1
    powershell -ExecutionPolicy Bypass -File .\setup\setup.ps1 --cchh
    powershell -ExecutionPolicy Bypass -File .\setup\setup.ps1 --autostart
    powershell -ExecutionPolicy Bypass -File .\setup\setup.ps1 --no-login
    powershell -ExecutionPolicy Bypass -File .\setup\setup.ps1 --dry-run

  Options:
    --cchh           also point cc-haha at the bridge (backs up its config)
    --autostart      register a Windows Scheduled Task that starts the bridge at logon
    --no-login       skip the device-code login step
    --dry-run        plan only: no install, no start, no login, no config changes
    --skip-selftest  skip the final chat self-test
    --port <n>       preferred bridge port (default 8793; auto-falls back if busy)
    --model <name>   model used for selftest and cc-haha (default deepseek-v4.1-flash)

  Exit codes: 0 ok / 1 failure / 3 login expired / 4 selftest failed / 5 env problem
  The script is idempotent: rerunning it is safe.
#>

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ---- parse args (both --flag and --flag=value are accepted) -----------------
$Port = 0
$PortGiven = $false
$Model = 'deepseek-v4.1-flash'
$DoCchh = $false
$Autostart = $false
$NoLogin = $false
$DryRun = $false
$SkipSelftest = $false

$i = 0
while ($i -lt $args.Count) {
  $a = [string]$args[$i]
  $next = if ($i + 1 -lt $args.Count) { [string]$args[$i + 1] } else { '' }
  switch -Regex ($a) {
    '^--cchh$'          { $DoCchh = $true }
    '^--autostart$'     { $Autostart = $true }
    '^--no-login$'      { $NoLogin = $true }
    '^--dry-run$'       { $DryRun = $true }
    '^--skip-selftest$' { $SkipSelftest = $true }
    '^--port$'          { $Port = [int]$next; $PortGiven = $true; $i++ }
    '^--port=(.+)$'     { $Port = [int]$Matches[1]; $PortGiven = $true }
    '^--model$'         { $Model = $next; $i++ }
    '^--model=(.+)$'    { $Model = $Matches[1] }
    '^(-h|--help|-|\?)$' {
      Get-Content -LiteralPath $PSCommandPath | Select-Object -First 34 | ForEach-Object { $_ -replace '^<#|^#?>?', '' }
      exit 0
    }
    default { Write-Host "[x] Unknown argument: $a (see --help)" -ForegroundColor Red; exit 5 }
  }
  $i++
}

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location -LiteralPath $Root

# Without --port, reuse WORKBUDDY_PORT from an existing .env (reruns must not
# drift to another port); fall back to 8793.
if (-not $PortGiven) {
  $envPath = Join-Path $Root '.env'
  $fromEnv = ''
  if (Test-Path -LiteralPath $envPath) {
    foreach ($line in [System.IO.File]::ReadAllLines($envPath)) {
      if ($line -match '^\s*(export\s+)?WORKBUDDY_PORT\s*=\s*(.+?)\s*$') { $fromEnv = $Matches[2].Trim('"').Trim("'") }
    }
  }
  $Port = if ($fromEnv -match '^\d+$') { [int]$fromEnv } else { 8793 }
}
$Helper = Join-Path $Root 'setup\lib\setup-helper.mjs'
$CchhConfig = Join-Path $Root 'setup\lib\cchh-config.mjs'
$NodeExe = $null

function Info($msg) { Write-Host ''; Write-Host "==> $msg" -ForegroundColor Cyan }
function Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Die($msg, $code = 1) { Write-Host "[x] $msg" -ForegroundColor Red; exit $code }
function Dry($msg) { if ($DryRun) { Write-Host "    [dry-run] $msg" -ForegroundColor DarkGray } }

function Invoke-Node {
  # Run the helper with the resolved node binary; its stdout/stderr go straight
  # to the console. Emits nothing itself (callers check $LASTEXITCODE).
  & $script:NodeExe @args
}

# ---- 1. Node.js -------------------------------------------------------------
Info 'Checking Node.js (need >= 20)'
$candidates = @()
$cmd = Get-Command node -ErrorAction SilentlyContinue
if ($cmd) { $candidates += $cmd.Source }
$candidates += @(
  "$env:ProgramFiles\nodejs\node.exe",
  "${env:ProgramFiles(x86)}\nodejs\node.exe",
  "$env:LOCALAPPDATA\Programs\nodejs\node.exe"
)
foreach ($c in $candidates) {
  if ($c -and (Test-Path -LiteralPath $c)) { $NodeExe = $c; break }
}
if (-not $NodeExe) {
  @(
    '[x] Node.js not found.',
    '    Install Node.js 20 or newer, then run this script again:',
    '      winget install OpenJS.NodeJS.LTS',
    '    or download from https://nodejs.org/ (LTS; keep clicking Next).'
  ) | ForEach-Object { Write-Host $_ -ForegroundColor Red }
  exit 5
}
$major = [int]((& $NodeExe -p 'process.versions.node.split(".")[0]').Trim())
if ($major -lt 20) { Die "Node.js is too old: $(& $NodeExe -v). Need Node >= 20." 5 }
$npm = Get-Command npm -ErrorAction SilentlyContinue
if (-not $npm) { Die 'Found node but not npm. Please install the full Node.js distribution (npm included).' 5 }
Invoke-Node $Helper noop
if ($LASTEXITCODE -ne 0) { Die 'Node environment check failed' 5 }
Write-Host "    Node $((& $NodeExe -v).Trim()) via $NodeExe"
# npm on Windows is npm.cmd; Get-Command resolves it correctly.
$NpmExe = $npm.Source

# ---- 2. Port ----------------------------------------------------------------
Info "Checking bridge port (requested: $Port)"
# A running bridge on this port is the NORMAL rerun case: keep its port and
# reuse it (idempotent). Do NOT auto-pick another port here, otherwise a rerun
# would repoint .env / cc-haha at an empty port while the real bridge keeps
# serving the old one. A *foreign* program holding the port is detected later
# from the bridge's own /health; the user can then rerun with --port <n>.
$null = & $NodeExe $Helper port $Port
$portFree = ($LASTEXITCODE -eq 0)
if ($portFree) {
  Write-Host "    Port $Port is free"
} else {
  Write-Host "    Port $Port is already in use (a running bridge is expected on reruns)"
}

# ---- 3. .env (idempotent: only append missing keys) -------------------------
Info 'Preparing .env (local config only; git-ignored; contains no upstream credentials)'
$EnvFile = Join-Path $Root '.env'
$EnvUtf8 = New-Object System.Text.UTF8Encoding($false) # no BOM

function Get-EnvKeyLine($key) {
  if (-not (Test-Path -LiteralPath $EnvFile)) { return $null }
  $lines = [System.IO.File]::ReadAllLines($EnvFile)
  foreach ($line in $lines) {
    if ($line -match "^\s*(export\s+)?$([regex]::Escape($key))=") { return $line }
  }
  return $null
}

function Set-EnvKey($key, $value) {
  $existing = Get-EnvKeyLine $key
  if ($existing) {
    Write-Host "    .env already has $key, leaving it unchanged"
    return
  }
  $prefix = "# Generated by setup/setup.ps1. Git-ignored.`r`n"
  if (Test-Path -LiteralPath $EnvFile) {
    $bytes = [System.IO.File]::ReadAllBytes($EnvFile)
    if ($bytes.Length -gt 0) {
      # ASCII 10 = LF, 13 = CR. Only add a separator when the file lacks one.
      $last = $bytes[$bytes.Length - 1]
      $prefix = if ($last -eq 10 -or $last -eq 13) { '' } else { "`r`n" }
    }
  }
  [System.IO.File]::AppendAllText($EnvFile, "$prefix$key=$value`r`n", $EnvUtf8)
  Write-Host "    .env: set $key=$value"
}

# Process env beats .env (config.mjs), so a stale WORKBUDDY_PORT would silently
# override the file. setup uses .env as the source of truth: warn, and pass the
# resolved port explicitly to every child (Start-Process + node invocations).
if ($env:WORKBUDDY_PORT -and $env:WORKBUDDY_PORT -ne "$Port") {
  Warn "WORKBUDDY_PORT=$($env:WORKBUDDY_PORT) is set in this shell and would override .env; using $Port for this run (unset it to silence this)."
}
$env:WORKBUDDY_PORT = "$Port"

if ($DryRun) {
  Dry "ensure .env has WORKBUDDY_HOST=127.0.0.1 / WORKBUDDY_PORT=$Port / WORKBUDDY_ANTHROPIC_MODEL=$Model"
} else {
  Set-EnvKey 'WORKBUDDY_HOST' '127.0.0.1'
  Set-EnvKey 'WORKBUDDY_PORT' "$Port"
  Set-EnvKey 'WORKBUDDY_ANTHROPIC_MODEL' $Model
}

# ---- 4. npm install ---------------------------------------------------------
Info 'Installing dependencies (npm install)'
$NodeModules = Join-Path $Root 'node_modules'
if ($DryRun) {
  Dry 'npm install --no-audit --no-fund'
} elseif (Test-Path -LiteralPath $NodeModules) {
  Write-Host '    node_modules already exists, skipping (delete it to force a reinstall)'
} else {
  & $NpmExe install --no-audit --no-fund
  if ($LASTEXITCODE -ne 0) { Die 'npm install failed' }
}

# Token file. The path is derived here; the helper only creates the file
# (--no-print, so no stdout is captured). Never print the token value.
if ($env:WORKBUDDY_LOCAL_TOKEN) {
  $TokenFile = 'env:WORKBUDDY_LOCAL_TOKEN'
  Write-Host '    Local token: from environment variable WORKBUDDY_LOCAL_TOKEN'
} else {
  $DataRoot = if ($env:WORKBUDDY_DATA_DIR) { $env:WORKBUDDY_DATA_DIR } else { Join-Path $HOME '.workbuddy-bridge' }
  $TokenFile = Join-Path $DataRoot 'bridge-token'
  & $NodeExe $Helper ensure-token --no-print
  if ($LASTEXITCODE -ne 0) { Die 'Could not prepare the local token file' }
  Write-Host "    Local token file: $TokenFile (contents not printed)"
}

# ---- 5. Start the bridge (background) --------------------------------------
Info 'Starting the bridge'
$DataDir = Join-Path $HOME '.workbuddy-bridge'
$LogDir = Join-Path $DataDir 'logs'
$BridgeLog = Join-Path $LogDir 'bridge.log'
$PidFile = Join-Path $DataDir 'bridge.pid'
if (-not $DryRun) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null }

# A running bridge answers /health with a build field (see setup-helper is-bridge).
function Test-BridgeHere {
  $null = & $NodeExe $Helper is-bridge $Port
  return ($LASTEXITCODE -eq 0)
}

if ($DryRun) {
  Dry "Start-Process node -ArgumentList bridge\launch.mjs (log: $BridgeLog)"
} elseif (Test-BridgeHere) {
  Write-Host "    A WorkBuddy bridge is already running on port $Port; skipping start"
} else {
  # launch.mjs spawns the real bridge as a child; stopping launch.mjs's tree stops both.
  $bridgeScript = Join-Path $Root 'bridge\launch.mjs'
  $startParams = @{
    FilePath               = $NodeExe
    WorkingDirectory       = $Root
    PassThru               = $true
    RedirectStandardOutput = $BridgeLog
    RedirectStandardError  = "$BridgeLog.err"
  }
  # -WindowStyle only exists on Windows PowerShell; use it there only.
  if ($IsWindows -or ($PSVersionTable.PSEdition -ne 'Core' -and $env:OS -eq 'Windows_NT')) {
    $startParams.ArgumentList = @("`"$bridgeScript`"")
    $startParams.WindowStyle = 'Hidden'
  } else {
    $startParams.ArgumentList = @($bridgeScript)
  }
  try {
    $proc = Start-Process @startParams
  } catch {
    Die "Could not start the bridge: $($_.Exception.Message)" 1
  }
  Set-Content -LiteralPath $PidFile -Value $proc.Id -Encoding ascii
  Write-Host "    Started, PID $($proc.Id), log $BridgeLog"
  # Wait until it answers /health, so login/self-test never race a binding port.
  # (Do not use $proc.HasExited: with redirection it waits for the child to exit.)
  $ready = $false
  for ($n = 0; $n -lt 40; $n++) {
    if (Test-BridgeHere) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
  }
  if (-not $ready) {
    Warn "The bridge did not come up on port $Port. Last log lines:"
    if (Test-Path -LiteralPath $BridgeLog) { Get-Content -LiteralPath $BridgeLog -Tail 8 | Write-Host }
    if (Test-Path -LiteralPath "$BridgeLog.err") { Get-Content -LiteralPath "$BridgeLog.err" -Tail 8 | Write-Host }
    Die 'Could not start the bridge' 4
  }
}
$BridgeHost = '127.0.0.1'

# ---- 6. Device login --------------------------------------------------------
if ($NoLogin) {
  Info 'Skipping device login (--no-login)'
} elseif ($DryRun) {
  Info 'Device login (dry run: not requested)'
  Dry "node $Helper login $BridgeHost $Port"
} else {
  Info 'Device login: open the URL below in your browser and finish signing in'
  # Existing desktop credentials make the poll return ready immediately.
  Invoke-Node $Helper login $BridgeHost $Port
  $rc = $LASTEXITCODE
  if ($rc -ne 0) {
    Die "Device login not completed (exit code $rc). You can rerun this script; a login link is valid for 10 minutes." $rc
  }
}

# ---- 7. Optional: cc-haha ---------------------------------------------------
$CchhDir = Join-Path $HOME '.claude\cc-haha'
if ($env:CLAUDE_CONFIG_DIR) { $CchhDir = Join-Path $env:CLAUDE_CONFIG_DIR 'cc-haha' }
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

if ($DoCchh) {
  Info "Configuring cc-haha (default -> local bridge, model $Model)"
  Write-Host "    Config dir: $CchhDir"
  Write-Host '    The token is not stored in the config; cc-haha reads it at launch (see SETUP-AUTO.md).'
  if ($DryRun) {
    Dry "back up providers.json / settings.json to *.bak-$Stamp"
    Dry "providers.json: activeId=workbuddy-bridge, baseUrl=http://127.0.0.1:$Port, apiKey empty"
    Dry "settings.json: model and ANTHROPIC_*MODEL = $Model, CC_HAHA_GROK_OAUTH_PROVIDER=0"
  } else {
    New-Item -ItemType Directory -Force -Path $CchhDir | Out-Null
    # Backups are made inside cchh-config.mjs (idempotent per stamp).
    & $NodeExe $CchhConfig --dir $CchhDir --port "$Port" --model $Model --stamp $Stamp
    if ($LASTEXITCODE -ne 0) { Die 'cc-haha configuration failed' }
    Write-Host ''
    Write-Host '    cc-haha still needs the token injected at launch. Pick one:'
    Write-Host '      a) In the shell that starts cc-haha:'
    Write-Host "           `$env:ANTHROPIC_AUTH_TOKEN = (Get-Content -Raw '$TokenFile').Trim()"
    Write-Host '      b) If you use a launcher script, make it read the same token file.'
    Write-Host '    Details: SETUP-AUTO.md, section "cc-haha".'
  }
} else {
  Info 'cc-haha configuration not requested (add --cchh)'
}

# ---- 8. Optional: autostart (Scheduled Task at logon) -----------------------
$TaskName = 'WorkBuddyBridge'
if ($Autostart) {
  Info 'Registering autostart (Scheduled Task at logon)'
  if ($DryRun) {
    Dry "Register-ScheduledTask ${TaskName} running node bridge\launch.mjs (at logon)"
  } else {
    $action = New-ScheduledTaskAction -Execute $NodeExe `
      -Argument "`"$(Join-Path $Root 'bridge\launch.mjs')`"" -WorkingDirectory $Root
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
      -DontStopIfGoingOnBatteries -StartWhenAvailable `
      -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
      -ExecutionTimeLimit (New-TimeSpan -Days 0)
    try {
      Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Description 'WorkBuddy local bridge (workbuddy-to-dsh)' -Force | Out-Null
      Write-Host "    Registered scheduled task: $TaskName"
    } catch {
      Warn "Could not register scheduled task: $($_.Exception.Message)"
    }
  }
} else {
  Write-Host ''
  Write-Host '    Tip: add --autostart to start the bridge automatically at logon.'
}

# ---- 9. Self-test -----------------------------------------------------------
if ($SkipSelftest) {
  Info 'Skipping self-test (--skip-selftest)'
} elseif ($DryRun) {
  Info 'Self-test (dry run: no chat request)'
  Dry "POST http://127.0.0.1:$Port/v1/chat/completions, expect the reply to contain the success marker"
} else {
  if ($NoLogin) {
    Info 'Self-test: trying a real chat (falls back to a port check if not signed in)'
    Invoke-Node $Helper chat $BridgeHost $Port
    if ($LASTEXITCODE -ne 0) {
      Warn 'Chat self-test failed (--no-login: you may not be signed in yet, or the model is temporarily unavailable). Rerun without --no-login to sign in.'
      $null = & $NodeExe $Helper port $Port
      if ($LASTEXITCODE -eq 0) { Die "Nothing answers on port $Port" 4 }
      Write-Host "    Bridge answers on $Port (conversation not verified)"
    }
  } else {
    Info 'Self-test: one chat request, expect the reply to contain the success marker'
    Invoke-Node $Helper chat $BridgeHost $Port
    if ($LASTEXITCODE -ne 0) { Die 'Chat self-test failed (see output above)' 4 }
  }
}

Info 'Done'
@(
  "  Bridge     http://127.0.0.1:$Port/v1",
  "  Model      $Model",
  "  Token file $TokenFile (do not paste its contents or commit it)",
  "  Log        $BridgeLog",
  "  Stop       Stop-Process -Id (Get-Content '$PidFile') -ErrorAction SilentlyContinue"
) | ForEach-Object { Write-Host $_ }
exit 0
