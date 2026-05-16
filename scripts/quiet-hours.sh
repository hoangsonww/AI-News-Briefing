#!/bin/bash
set -euo pipefail

# quiet-hours.sh — Pause or resume the macOS launchd job for the daily briefing.
# This is a macOS-only convenience wrapper around `launchctl` that records a
# small state file so subsequent runs can see whether the agent is paused.
#
# Linux/Windows: this is a no-op with a hint.
#
# Usage:
#   bash scripts/quiet-hours.sh                  # show status
#   bash scripts/quiet-hours.sh --pause          # unload the plist
#   bash scripts/quiet-hours.sh --resume         # reload the plist
#   bash scripts/quiet-hours.sh --status         # explicit status
#   bash scripts/quiet-hours.sh --json           # machine-readable

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/com.ainews.briefing.plist"
STATE_FILE="$SCRIPT_DIR/logs/.quiet-state"

ACTION="status"
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --pause)  ACTION="pause";  shift ;;
    --resume) ACTION="resume"; shift ;;
    --status) ACTION="status"; shift ;;
    --json)   JSON=1; shift ;;
    -h|--help)
      sed -n '4,15p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
  G='\033[32m'; R='\033[31m'; Y='\033[33m'; D='\033[90m'; B='\033[1m'; Z='\033[0m'
else
  G=''; R=''; Y=''; D=''; B=''; Z=''
fi

OS="$(uname -s 2>/dev/null || echo unknown)"

if [ "$OS" != "Darwin" ]; then
  if [ "$JSON" -eq 1 ]; then
    printf '{"platform":"%s","supported":false,"hint":"quiet-hours only supports macOS launchd."}\n' "$OS"
  else
    printf "  ${Y}quiet-hours is macOS-only.${Z}\n"
    printf "  ${D}Linux: edit your crontab. Windows: use install-task.ps1 -Uninstall.${Z}\n"
  fi
  exit 0
fi

mkdir -p "$(dirname "$STATE_FILE")"

is_loaded() {
  launchctl list 2>/dev/null | grep -q "ainews"
}

write_state() {
  printf 'paused_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STATE_FILE"
}

clear_state() {
  rm -f "$STATE_FILE"
}

read_paused_at() {
  [ -f "$STATE_FILE" ] || return 1
  grep '^paused_at=' "$STATE_FILE" 2>/dev/null | sed 's/^paused_at=//'
}

do_pause() {
  if [ ! -f "$PLIST" ]; then
    echo "ERROR: launchd plist not installed at $PLIST" >&2
    echo "Run: make install" >&2
    return 1
  fi
  if is_loaded; then
    launchctl unload "$PLIST" 2>/dev/null || true
  fi
  write_state
}

do_resume() {
  if [ ! -f "$PLIST" ]; then
    echo "ERROR: launchd plist not installed at $PLIST" >&2
    echo "Run: make install" >&2
    return 1
  fi
  if ! is_loaded; then
    launchctl load "$PLIST"
  fi
  clear_state
}

emit_status() {
  local loaded paused since
  loaded="no"; is_loaded && loaded="yes"
  paused="no"
  since=""
  if [ -f "$STATE_FILE" ]; then
    since="$(read_paused_at 2>/dev/null || echo "")"
    paused="yes"
  fi
  if [ "$JSON" -eq 1 ]; then
    printf '{"platform":"darwin","plist":"%s","loaded":"%s","paused":"%s","paused_at":"%s"}\n' \
      "$PLIST" "$loaded" "$paused" "$since"
    return
  fi
  echo ""
  printf "  ${B}quiet-hours${Z}\n"
  echo "  ============================="
  printf "  %-12s %s\n" "plist:"     "$PLIST"
  if [ "$loaded" = "yes" ]; then
    printf "  %-12s ${G}loaded${Z}\n" "launchd:"
  else
    printf "  %-12s ${Y}not loaded${Z}\n" "launchd:"
  fi
  if [ "$paused" = "yes" ]; then
    printf "  %-12s ${Y}paused${Z}  (since %s)\n" "state:" "${since:-?}"
    printf "\n  ${D}Resume with: bash scripts/quiet-hours.sh --resume${Z}\n"
  else
    printf "  %-12s ${G}active${Z}\n" "state:"
    printf "\n  ${D}Pause with: bash scripts/quiet-hours.sh --pause${Z}\n"
  fi
  echo ""
}

case "$ACTION" in
  pause)
    do_pause
    [ "$JSON" -eq 0 ] && printf "  ${G}Paused${Z} launchd briefing job. No runs until you resume.\n"
    emit_status ;;
  resume)
    do_resume
    [ "$JSON" -eq 0 ] && printf "  ${G}Resumed${Z} launchd briefing job.\n"
    emit_status ;;
  status)
    emit_status ;;
esac
