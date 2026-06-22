#Requires -Version 5.1

<#
.SYNOPSIS
    Daily AI news briefing with multi-engine fallback.
.DESCRIPTION
    Runs the daily AI news briefing pipeline. Supports multiple AI CLI engines
    (Claude Code, Codex, Gemini, Copilot) with automatic fallback if one fails.
.PARAMETER BriefingDate
    Override the briefing date (YYYY-MM-DD). Default: today.
.PARAMETER Cli
    AI engine to use: claude, codex, gemini, copilot.
    If omitted, reads AI_BRIEFING_CLI env var; if unset, tries each in order.
.PARAMETER Catchup
    Scheduled mode: run today only if not already done and it is at/after 08:00
    in AI_BRIEFING_TZ (default Pacific). Lets a frequently-repeating task post
    exactly once per Pacific day. Never back-fills missed days.
.NOTES
    AI_BRIEFING_TZ controls the briefing's "today" and the 08:00 schedule
    (default "Pacific Standard Time"; PST/PDT handled automatically).
.EXAMPLE
    .\briefing.ps1
.EXAMPLE
    .\briefing.ps1 -Cli codex
.EXAMPLE
    .\briefing.ps1 -BriefingDate 2026-04-01 -Cli gemini
#>

param(
    [string]$BriefingDate = "",
    [ValidateSet("claude", "codex", "gemini", "copilot", "")]
    [string]$Cli = "",
    [switch]$Catchup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$LogDir = Join-Path $ScriptDir "logs"

# Prevent nested Claude Code sessions
$env:CLAUDECODE = $null

# Refresh persistent env vars from registry (User scope -> Process scope)
foreach ($name in @("AI_BRIEFING_TEAMS_WEBHOOK", "AI_BRIEFING_SLACK_WEBHOOK", "AI_BRIEFING_CLI", "AI_BRIEFING_MODEL", "AI_BRIEFING_TZ")) {
    $val = [Environment]::GetEnvironmentVariable($name, "User")
    if ($val) { [Environment]::SetEnvironmentVariable($name, $val, "Process") }
}

# -- Briefing timezone -----------------------------------------
# The notion of "today" and the 08:00 schedule follow this timezone (default
# Pacific) regardless of the host machine's clock. Use a Windows zone id --
# "Pacific Standard Time" already covers PST/PDT (DST handled automatically).
# On PowerShell 7+ an IANA id such as "America/Los_Angeles" also resolves.
# Override with AI_BRIEFING_TZ.
$BriefTz = if ($env:AI_BRIEFING_TZ) { $env:AI_BRIEFING_TZ } else { "Pacific Standard Time" }
function Get-BriefNow {
    try {
        $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById($BriefTz)
        return [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $tz)
    } catch {
        return (Get-Date)  # unknown id (e.g. an IANA name on PS 5.1) -> host local
    }
}
$BriefNow = Get-BriefNow
$Date = if ($BriefingDate) { $BriefingDate } else { $BriefNow.ToString("yyyy-MM-dd") }
$LogFile = Join-Path $LogDir "$Date.log"

if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

# -- Logging ---------------------------------------------------
function Write-Log {
    param([string]$Message)
    $ts = (Get-BriefNow).ToString("HH:mm:ss")
    "$Date $ts $Message" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

# -- Catch-up guard (scheduled -Catchup runs only) -------------
# All times are in BriefTz (Pacific by default), not the host clock. Run today
# only if not already done and it is at/after 08:00; before then, defer to a
# later repetition. Mirrors the macOS/launchd catch-up behavior so the task can
# poll often and still post exactly once per Pacific day.
if ($Catchup) {
    $cardPath = Join-Path $LogDir "$Date-card.json"
    if (Test-Path $cardPath) {
        Write-Log "Catch-up: briefing for $Date already done; skipping."
        exit 0
    }
    $hhmm = [int]((Get-BriefNow).ToString("HHmm"))
    if ($hhmm -lt 800) {
        Write-Log "Catch-up: before 08:00 $BriefTz (now $hhmm); deferring to a later run."
        exit 0
    }
    Write-Log "Catch-up: no briefing yet for $Date and now is $hhmm $BriefTz; running."
}

Write-Log "Starting AI News Briefing..."

# -- CLI Engine Registry ---------------------------------------
$FallbackChain = @("claude", "codex", "gemini", "copilot")

function Resolve-CliBinary {
    param([string]$CliName)
    switch ($CliName) {
        "claude" {
            foreach ($p in @(
                (Join-Path $env:USERPROFILE ".local\bin\claude.exe"),
                (Join-Path $env:USERPROFILE ".local\bin\claude")
            )) {
                if (Test-Path $p) { return $p }
            }
            $cmd = Get-Command "claude" -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
            return $null
        }
        "codex" {
            $cmd = Get-Command "codex" -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
            return $null
        }
        "gemini" {
            $cmd = Get-Command "gemini" -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
            return $null
        }
        "copilot" {
            $cmd = Get-Command "copilot" -ErrorAction SilentlyContinue
            if ($cmd) { return $cmd.Source }
            return $null
        }
        default { return $null }
    }
}

function Invoke-Engine {
    param(
        [string]$CliName,
        [string]$Binary,
        [string]$Prompt
    )

    $model = if ($env:AI_BRIEFING_MODEL) { $env:AI_BRIEFING_MODEL } else { "opus" }

    try {
        $output = switch ($CliName) {
            "claude"  { & $Binary -p --model $model --dangerously-skip-permissions $Prompt 2>&1 }
            "codex"   { & $Binary exec --full-auto $Prompt 2>&1 }
            "gemini"  { & $Binary -p $Prompt 2>&1 }
            "copilot" {
                & $Binary --prompt $Prompt --allow-all-tools --allow-all-paths --allow-all-urls 2>&1
            }
        }
        $output | Out-File -FilePath $LogFile -Append -Encoding utf8
        return $(if ($null -ne $LASTEXITCODE) { $LASTEXITCODE } else { 1 })
    } catch {
        "ERROR: $_" | Out-File -FilePath $LogFile -Append -Encoding utf8
        return 1
    }
}

# -- Prompt assembly -------------------------------------------
$PromptFile = Join-Path $ScriptDir "prompt.md"
if (-not (Test-Path $PromptFile)) {
    Write-Log "ERROR: prompt.md not found at $PromptFile"
    exit 1
}

$Prompt = Get-Content -Path $PromptFile -Raw

$today = $BriefNow.ToString("yyyy-MM-dd")
if ($Date -ne $today) {
    $datePrefix = @"
BRIEFING DATE OVERRIDE: $Date
Generate the briefing for $Date, NOT today ($today).
Search for AI news from $Date (past 24 hours relative to that date).
The Notion page title should use $Date.
The card.json filename should use $Date (logs/$Date-card.json).
---

"@
    $Prompt = $datePrefix + $Prompt
    Write-Log "Date override: generating briefing for $Date"
}

# -- Execution with fallback -----------------------------------
$Preferred = if ($Cli) { $Cli } elseif ($env:AI_BRIEFING_CLI) { $env:AI_BRIEFING_CLI } else { "" }
$Success = $false
$UsedCli = ""

if ($Preferred) {
    # Explicit engine chosen
    $binary = Resolve-CliBinary -CliName $Preferred
    if (-not $binary) {
        Write-Log "ERROR: Requested engine '$Preferred' is not installed."
        exit 1
    }
    Write-Log "Engine: $Preferred ($binary)"

    $exitCode = Invoke-Engine -CliName $Preferred -Binary $binary -Prompt $Prompt
    if ($exitCode -eq 0) {
        $Success = $true
        $UsedCli = $Preferred
    } else {
        Write-Log "Briefing FAILED with $Preferred (exit code $exitCode)."
    }
} else {
    # Fallback chain
    foreach ($cli in $FallbackChain) {
        $binary = Resolve-CliBinary -CliName $cli
        if (-not $binary) {
            Write-Log "Engine ${cli}: not found, skipping."
            continue
        }
        Write-Log "Attempting with $cli ($binary)..."

        $exitCode = Invoke-Engine -CliName $cli -Binary $binary -Prompt $Prompt
        if ($exitCode -eq 0) {
            $Success = $true
            $UsedCli = $cli
            break
        }

        Write-Log "$cli failed (exit $exitCode). Trying next engine..."
    }
}

# -- Post-processing -------------------------------------------
if ($Success) {
    Write-Log "Briefing complete. Engine: $UsedCli. Check Notion for today's report."

    $CardFile = Join-Path $LogDir "$Date-card.json"

    # Teams notification
    $teamsScript = Join-Path $ScriptDir "scripts\notify-teams.ps1"
    if ((Test-Path $teamsScript) -and $env:AI_BRIEFING_TEAMS_WEBHOOK) {
        Write-Log "Sending Teams notification..."
        try {
            & $teamsScript -All -CardFile $CardFile
            Write-Log "Teams notification sent."
        } catch {
            Write-Log "Teams notification failed: $_"
        }
    }

    # Slack notification
    $slackScript = Join-Path $ScriptDir "scripts\notify-slack.ps1"
    if ((Test-Path $slackScript) -and $env:AI_BRIEFING_SLACK_WEBHOOK) {
        Write-Log "Sending Slack notification..."
        try {
            & $slackScript -All -CardFile $CardFile
            Write-Log "Slack notification sent."
        } catch {
            Write-Log "Slack notification failed: $_"
        }
    }

    # Publish to Obsidian vault if configured
    $obsidianScript = Join-Path $ScriptDir "scripts\publish-obsidian.ps1"
    $obsidianFile = Join-Path $LogDir "$Date-obsidian.md"
    $obsidianVault = $env:AI_BRIEFING_OBSIDIAN_VAULT
    if (-not $obsidianVault) {
        $obsidianVault = [Environment]::GetEnvironmentVariable("AI_BRIEFING_OBSIDIAN_VAULT", "User")
    }
    if ((Test-Path $obsidianScript) -and $obsidianVault) {
        if (Test-Path $obsidianFile) {
            Write-Log "Publishing to Obsidian vault..."
            try {
                & $obsidianScript -File $obsidianFile
                Write-Log "Obsidian publish complete."
            } catch {
                Write-Log "Obsidian publish failed: $_"
            }
        } else {
            Write-Log "Obsidian skipped -- markdown file not found."
        }
    }
} else {
    Write-Log "Briefing FAILED -- all engines exhausted or selected engine failed."
}

# -- Cleanup ---------------------------------------------------
Get-ChildItem -Path $LogDir -Filter "*.log" -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
    Remove-Item -Force -ErrorAction SilentlyContinue
