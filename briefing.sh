#!/bin/bash
# AI News Briefing - Daily automated pipeline with multi-engine fallback.
#
# Supported engines: claude, codex, gemini, copilot
# - Set AI_BRIEFING_CLI env var or pass --cli to lock to a specific engine
# - If unset, tries each in order until one succeeds (claude -> codex -> gemini -> copilot)
#
# Usage:
#   briefing.sh                                # today, auto-fallback
#   briefing.sh 2026-04-01                     # backfill date (backward compat)
#   briefing.sh --cli codex                    # lock to codex
#   briefing.sh --cli gemini --date 2026-04-01 # both

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"

# The prompt tells the engine to read/write relative paths (logs/covered-stories.txt,
# logs/$DATE-card.json, etc). Under launchd the cwd is "/", so those resolve to /logs
# and fail read-only. Pin cwd to the project dir so every engine sees the real logs/.
cd "$SCRIPT_DIR" || { echo "ERROR: cannot cd to $SCRIPT_DIR" >&2; exit 1; }

# -- Argument parsing ------------------------------------------
CLI_ARG=""
DATE_ARG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cli|-c)
      [[ $# -lt 2 ]] && { echo "ERROR: --cli requires a value" >&2; exit 1; }
      CLI_ARG="$2"; shift 2 ;;
    --date|-d)
      [[ $# -lt 2 ]] && { echo "ERROR: --date requires a value" >&2; exit 1; }
      DATE_ARG="$2"; shift 2 ;;
    --help|-h)
      cat <<'USAGE'
Usage: briefing.sh [OPTIONS] [DATE]

Run the daily AI news briefing pipeline.

Options:
  --cli, -c ENGINE   AI engine: claude, codex, gemini, copilot
  --date, -d DATE    Briefing date (YYYY-MM-DD), default: today
  --help, -h         Show this help

Environment:
  AI_BRIEFING_CLI    Default engine (overridden by --cli)
  AI_BRIEFING_MODEL  Model name (default: opus for claude)
USAGE
      exit 0 ;;
    -*)
      echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      DATE_ARG="$1"; shift ;;
  esac
done

DATE="${DATE_ARG:-$(date +%Y-%m-%d)}"
TODAY=$(date +%Y-%m-%d)
TIME=$(date +%H:%M:%S)
LOG_FILE="$LOG_DIR/$DATE.log"

# Prevent nested Claude Code sessions
unset CLAUDECODE 2>/dev/null || true

mkdir -p "$LOG_DIR"

# -- Logging ---------------------------------------------------
write_log() {
  echo "[$DATE $(date +%H:%M:%S)] $1" >> "$LOG_FILE"
}

write_log "Starting AI News Briefing..."

# -- CLI Engine Registry ---------------------------------------
#
# Each engine needs:
#   resolve_binary <cli>   -> prints binary path or returns 1
#   run_engine <cli> <bin> <prompt> -> runs the engine, returns exit code
#
# Supported: claude | codex | gemini | copilot

FALLBACK_CHAIN="claude codex gemini copilot"

resolve_binary() {
  local cli="$1"
  case "$cli" in
    claude)
      for p in "${HOME}/.local/bin/claude" "${HOME}/.local/bin/claude.exe"; do
        if [ -x "$p" ]; then echo "$p"; return 0; fi
      done
      command -v claude 2>/dev/null && return 0
      return 1
      ;;
    codex)
      command -v codex 2>/dev/null && return 0
      return 1
      ;;
    gemini)
      command -v gemini 2>/dev/null && return 0
      return 1
      ;;
    copilot)
      command -v copilot 2>/dev/null && return 0
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

run_engine() {
  local cli="$1" binary="$2" prompt="$3"
  local model="${AI_BRIEFING_MODEL:-opus}"

  case "$cli" in
    claude)
      "$binary" -p \
        --model "$model" \
        --dangerously-skip-permissions \
        "$prompt" >> "$LOG_FILE" 2>&1
      ;;
    codex)
      # --skip-git-repo-check: under launchd codex can't confirm a trusted dir
      "$binary" exec --full-auto --skip-git-repo-check \
        "$prompt" >> "$LOG_FILE" 2>&1
      ;;
    gemini)
      # --skip-trust: non-interactive runs aren't in a "trusted" workspace by default
      "$binary" --skip-trust -p \
        "$prompt" >> "$LOG_FILE" 2>&1
      ;;
    copilot)
      "$binary" --prompt "$prompt" \
        --allow-all-tools --allow-all-paths --allow-all-urls >> "$LOG_FILE" 2>&1
      ;;
  esac
}

# -- Prompt assembly -------------------------------------------
if [ ! -f "$SCRIPT_DIR/prompt.md" ]; then
  write_log "ERROR: prompt.md not found at $SCRIPT_DIR/prompt.md"
  exit 1
fi

PROMPT="$(cat "$SCRIPT_DIR/prompt.md")"

DATE_PREFIX="BRIEFING DATE: $DATE
Use $DATE as today's date for this briefing. Ignore your own clock — the host may be in a different timezone.
Search for AI news from $DATE (past 24 hours relative to that date).
The Notion page title MUST use $DATE (e.g. \"$DATE\").
Do NOT create any page titled with any other date.
The card.json filename MUST be logs/$DATE-card.json.
---

"
PROMPT="${DATE_PREFIX}${PROMPT}"
if [[ "$DATE" != "$TODAY" ]]; then
  write_log "Date override: generating briefing for $DATE (host today is $TODAY)"
else
  write_log "Briefing date pinned to $DATE."
fi

# -- Execution with fallback -----------------------------------
PREFERRED="${CLI_ARG:-${AI_BRIEFING_CLI:-}}"
SUCCESS=false
USED_CLI=""

# Artifacts the engine is expected to produce. Success is gated on
# CARD_FILE existing, so clear any stale or partial artifacts before
# every attempt -- otherwise a previous run, or a prior engine in the
# fallback chain that wrote a partial file before failing, could make a
# later engine look successful when it produced nothing.
CARD_FILE_CHECK="$LOG_DIR/$DATE-card.json"
OBS_FILE_CHECK="$LOG_DIR/$DATE-obsidian.md"
clean_artifacts() { rm -f "$CARD_FILE_CHECK" "$OBS_FILE_CHECK"; }

if [ -n "$PREFERRED" ]; then
  # -- Explicit engine chosen ----------------------------------
  binary=$(resolve_binary "$PREFERRED" 2>/dev/null) || {
    write_log "ERROR: Requested engine '$PREFERRED' is not installed."
    exit 1
  }
  write_log "Engine: $PREFERRED ($binary)"

  clean_artifacts
  run_engine "$PREFERRED" "$binary" "$PROMPT"
  exit_code=$?

  if [ $exit_code -eq 0 ] && [ -f "$CARD_FILE_CHECK" ]; then
    SUCCESS=true
    USED_CLI="$PREFERRED"
  elif [ $exit_code -eq 0 ]; then
    write_log "Briefing FAILED with $PREFERRED: exit 0 but no card.json produced (likely auth or MCP failure)."
    clean_artifacts
  else
    write_log "Briefing FAILED with $PREFERRED (exit code $exit_code)."
    clean_artifacts
  fi
else
  # -- Fallback chain ------------------------------------------
  for cli in $FALLBACK_CHAIN; do
    binary=$(resolve_binary "$cli" 2>/dev/null) || {
      write_log "Engine $cli: not found, skipping."
      continue
    }
    write_log "Attempting with $cli ($binary)..."

    clean_artifacts
    run_engine "$cli" "$binary" "$PROMPT"
    exit_code=$?

    if [ $exit_code -eq 0 ] && [ -f "$CARD_FILE_CHECK" ]; then
      SUCCESS=true
      USED_CLI="$cli"
      break
    fi

    if [ $exit_code -eq 0 ] && [ ! -f "$CARD_FILE_CHECK" ]; then
      write_log "$cli exited 0 but produced no card.json (likely auth or MCP failure). Trying next engine..."
    else
      write_log "$cli failed (exit $exit_code). Trying next engine..."
    fi
    clean_artifacts
  done
fi

# -- Post-processing -------------------------------------------
if $SUCCESS; then
  write_log "Briefing complete. Engine: $USED_CLI. Check Notion for today's report."

  CARD_FILE="$LOG_DIR/$DATE-card.json"

  # Teams notification
  TEAMS_SCRIPT="$SCRIPT_DIR/scripts/notify-teams.sh"
  if [[ -x "$TEAMS_SCRIPT" && -n "${AI_BRIEFING_TEAMS_WEBHOOK:-}" ]]; then
    write_log "Sending Teams notification..."
    if "$TEAMS_SCRIPT" --all --card-file "$CARD_FILE"; then
      write_log "Teams notification sent."
    else
      write_log "Teams notification failed."
    fi
  fi

  # Slack notification
  SLACK_SCRIPT="$SCRIPT_DIR/scripts/notify-slack.sh"
  if [[ -x "$SLACK_SCRIPT" && -n "${AI_BRIEFING_SLACK_WEBHOOK:-}" ]]; then
    write_log "Sending Slack notification..."
    if "$SLACK_SCRIPT" --all --card-file "$CARD_FILE"; then
      write_log "Slack notification sent."
    else
      write_log "Slack notification failed."
    fi
  fi

  # Publish to Obsidian vault if configured
  OBSIDIAN_SCRIPT="$SCRIPT_DIR/scripts/publish-obsidian.sh"
  OBSIDIAN_FILE="$LOG_DIR/$DATE-obsidian.md"
  if [[ -f "$OBSIDIAN_SCRIPT" && -n "${AI_BRIEFING_OBSIDIAN_VAULT:-}" ]]; then
    if [[ -f "$OBSIDIAN_FILE" ]]; then
      echo "[$DATE $(date +%H:%M:%S)] Publishing to Obsidian vault..." >> "$LOG_FILE"
      if bash "$OBSIDIAN_SCRIPT" --file "$OBSIDIAN_FILE"; then
        echo "[$DATE $(date +%H:%M:%S)] Obsidian publish complete." >> "$LOG_FILE"
      else
        echo "[$DATE $(date +%H:%M:%S)] Obsidian publish failed." >> "$LOG_FILE"
      fi
    else
      echo "[$DATE $(date +%H:%M:%S)] Obsidian skipped -- markdown file not found." >> "$LOG_FILE"
    fi
  fi
else
  write_log "Briefing FAILED -- all engines exhausted or selected engine failed."
fi

# -- Cleanup ---------------------------------------------------
find "$LOG_DIR" -name "*.log" -mtime +30 -delete 2>/dev/null || true
