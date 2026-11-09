# Register the WorkBuddy bridge watchdog as a Task Scheduler job (Windows).
#
# Run once, as the user who runs the bridge. Afterwards the bridge is re-started
# within a minute whenever it dies, which is what happens when the logon-triggered
# bridge task is killed along with the user session.
#
# Keep this file pure ASCII: Windows PowerShell 5.1 decodes BOM-less scripts with
# the ANSI code page.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\install-watchdog.ps1
#   powershell -ExecutionPolicy Bypass -File scripts\install-watchdog.ps1 -Uninstall

param(
    [switch]$Uninstall,
    [string]$TaskName = 'WorkBuddyBridgeWatchdog'
)

$ErrorActionPreference = 'Stop'

if ($Uninstall) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "removed scheduled task: $TaskName"
    exit 0
}

$watchdog = Join-Path $PSScriptRoot 'watchdog.ps1'
if (-not (Test-Path $watchdog)) { throw "watchdog script not found: $watchdog" }

$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $watchdog)

# Logon start, plus a one-minute repetition. The repetition duration must be a
# concrete span: [TimeSpan]::MaxValue is rejected at registration time.
$triggers = @(
    (New-ScheduledTaskTrigger -AtLogOn),
    (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) `
        -RepetitionInterval (New-TimeSpan -Minutes 1) `
        -RepetitionDuration (New-TimeSpan -Days 999))
)

$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers `
    -Settings $settings -Force `
    -Description 'Restart the WorkBuddy bridge if its port is not listening (checked every minute).' | Out-Null

Write-Host "registered scheduled task: $TaskName"
Get-ScheduledTask -TaskName $TaskName | Select-Object TaskName, State | Format-Table -AutoSize
