# WorkBuddy bridge watchdog (Windows).
#
# Checks whether the bridge is listening on its port, and starts it hidden when
# it is not. Intended to run from Task Scheduler once per minute: the bridge is
# started from a logon-triggered task, so it dies with the user session. This
# watchdog brings it back.
#
# Keep this file pure ASCII. Windows PowerShell 5.1 reads a BOM-less script with
# the ANSI code page, so non-ASCII comments corrupt parsing.
#
# Exit codes: 0 = healthy or started; 1 = could not start.

$ErrorActionPreference = 'Stop'

$root    = Split-Path -Parent $PSScriptRoot
$port    = if ($env:WORKBUDDY_PORT) { [int]$env:WORKBUDDY_PORT } else { 8793 }
$nodeExe = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $nodeExe) { $nodeExe = 'C:\Program Files\nodejs\node.exe' }
$launch  = Join-Path $root 'bridge\launch.mjs'
$logDir  = Join-Path $env:LOCALAPPDATA 'workbuddy-bridge\logs'
$logFile = Join-Path $logDir 'watchdog.log'

function Write-Log([string]$msg) {
    try {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
        Add-Content -Path $logFile -Value ("{0} {1}" -f (Get-Date -Format 's'), $msg) -Encoding UTF8
    } catch { }
}

function Test-Port([int]$p) {
    try {
        $conn = Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction Stop
        if ($conn) { return $true }
        return $false
    } catch {
        $out = & netstat -ano -p TCP 2>$null | Select-String -Pattern (":{0}\s+.*LISTENING" -f $p)
        return [bool]$out
    }
}

if (Test-Port $port) { exit 0 }

Write-Log "port $port down -> starting bridge"

if (-not (Test-Path $nodeExe)) { Write-Log "ERROR node not found: $nodeExe"; exit 1 }
if (-not (Test-Path $launch))  { Write-Log "ERROR launch not found: $launch"; exit 1 }

try {
    Start-Process -FilePath $nodeExe -ArgumentList "`"$launch`"" -WorkingDirectory $root -WindowStyle Hidden
    Start-Sleep -Seconds 3
    if (Test-Port $port) { Write-Log 'bridge up' } else { Write-Log 'WARN started but port still down' }
} catch {
    Write-Log ("ERROR start failed: " + $_.Exception.Message)
    exit 1
}
