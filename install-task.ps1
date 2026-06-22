#Requires -Version 5.1
<#
.SYNOPSIS
    Registers (or re-registers) the AI News Briefing scheduled task.
.DESCRIPTION
    Creates a Windows Task Scheduler task that runs briefing.ps1 at 8:00 AM
    Pacific (PST/PDT). Task Scheduler triggers fire in the HOST's local time and
    have no timezone field, so the task instead repeats every 30 minutes and
    briefing.ps1 -Catchup gates the actual run to 08:00 in AI_BRIEFING_TZ
    (default Pacific). This makes the run land at 08:00 Pacific on any host TZ.
    The -Hour/-Minute below add a punctual host-local anchor on top of the poll.
    Run this script from an elevated (admin) PowerShell prompt OR as your own user
    (the task will run under your account).
.EXAMPLE
    .\install-task.ps1
    .\install-task.ps1 -Hour 7 -Minute 30
#>
param(
    [int]$Hour = 8,
    [int]$Minute = 0
)

$ErrorActionPreference = "Stop"

$TaskName = "AiNewsBriefing"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$BriefingScript = Join-Path $ScriptDir "briefing.ps1"

if (-not (Test-Path $BriefingScript)) {
    Write-Error "briefing.ps1 not found at $BriefingScript"
    exit 1
}

# Remove existing task if present
$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing existing '$TaskName' task..."
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$BriefingScript`" -Catchup" `
    -WorkingDirectory $ScriptDir

# Two triggers, both running briefing.ps1 -Catchup (which gates to 08:00 Pacific):
#   1. A punctual daily anchor at the host-local -Hour:-Minute.
#   2. A 30-minute poll that repeats all day, so the run still lands within
#      ~30 min of 08:00 Pacific even when the host clock is in another zone or
#      the machine was asleep at the anchor time. The catch-up guard ensures
#      exactly one briefing per Pacific day regardless of how often it fires.
$dailyTrigger = New-ScheduledTaskTrigger -Daily -At ("{0:D2}:{1:D2}" -f $Hour, $Minute)
$pollTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date `
    -RepetitionInterval (New-TimeSpan -Minutes 30) `
    -RepetitionDuration ([TimeSpan]::MaxValue)

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 30)

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger @($dailyTrigger, $pollTrigger) `
    -Settings $settings `
    -Description "Daily AI news briefing (08:00 Pacific via -Catchup) using Claude Code CLI" `
    -RunLevel Limited

Write-Host ""
Write-Host "Task '$TaskName' registered: 08:00 Pacific via -Catchup (host-local anchor $("{0:D2}:{1:D2}" -f $Hour, $Minute) + 30-min poll)."
Write-Host "Set a different zone with: setx AI_BRIEFING_TZ `"Eastern Standard Time`""
Write-Host ""
Write-Host "Useful commands:"
Write-Host "  Run now:    schtasks /run /tn $TaskName"
Write-Host "  Check:      schtasks /query /tn $TaskName"
Write-Host "  Delete:     schtasks /delete /tn $TaskName /f"
$logExample = Join-Path $ScriptDir "logs" | Join-Path -ChildPath "$(Get-Date -Format 'yyyy-MM-dd').log"
Write-Host "  View log:   Get-Content `"$logExample`""
