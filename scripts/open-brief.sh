#!/bin/bash
set -euo pipefail

# open-brief.sh — Open today's (or a specified date's) briefing artifacts in
# the system's default application. Uses `open` on macOS, `xdg-open` on Linux,
# and falls back to printing the path if neither is available.
#
# Usage:
#   bash scripts/open-brief.sh                          # opens today's log
#   bash scripts/open-brief.sh --what card              # opens today's card.json
#   bash scripts/open-brief.sh --date 2026-03-18 --what notion
#   bash scripts/open-brief.sh --what obsidian
#   bash scripts/open-brief.sh --what dir               # logs/ in Finder/Explorer
#
# --what values: log (default) | card | obsidian | notion | dir | all

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"
DATE="$(date +%Y-%m-%d)"
WHAT="log"
DRY_RUN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --date)    DATE="$2"; shift 2 ;;
    --what)    WHAT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help)
      sed -n '4,15p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

opener=""
if command -v open >/dev/null 2>&1; then
  opener="open"
elif command -v xdg-open >/dev/null 2>&1; then
  opener="xdg-open"
fi

open_target() {
  local target="$1"
  if [ "$DRY_RUN" -eq 1 ] || [ -z "$opener" ]; then
    echo "$target"
    return 0
  fi
  "$opener" "$target" >/dev/null 2>&1 || {
    echo "WARN: $opener failed for $target" >&2
    echo "$target"
    return 1
  }
}

extract_notion_url() {
  local card="$1"
  [ -f "$card" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$card" <<'PY'
import json, sys
try:
    with open(sys.argv[1], "r", encoding="utf-8") as f:
        card = json.load(f)
except Exception:
    sys.exit(1)
content = card
if isinstance(content, dict) and "attachments" in content:
    atts = content.get("attachments") or []
    if atts and isinstance(atts[0], dict):
        content = atts[0].get("content", {})
for a in content.get("actions", []) or []:
    if isinstance(a, dict) and a.get("type") == "Action.OpenUrl" and a.get("url"):
        print(a["url"]); sys.exit(0)
sys.exit(1)
PY
}

handle_log() {
  local f="$LOG_DIR/$DATE.log"
  [ -f "$f" ] || { echo "ERROR: no log for $DATE at $f" >&2; return 1; }
  open_target "$f"
}

handle_card() {
  local f="$LOG_DIR/$DATE-card.json"
  if [ ! -f "$f" ]; then
    # Fall back to example-cards for convenience.
    local alt="$SCRIPT_DIR/example-cards/$DATE-card.json"
    if [ -f "$alt" ]; then f="$alt"
    else echo "ERROR: no card.json for $DATE" >&2; return 1; fi
  fi
  open_target "$f"
}

handle_obsidian() {
  local f="$LOG_DIR/$DATE-obsidian.md"
  [ -f "$f" ] || { echo "ERROR: no obsidian.md for $DATE at $f" >&2; return 1; }
  open_target "$f"
}

handle_notion() {
  local card="$LOG_DIR/$DATE-card.json"
  [ -f "$card" ] || card="$SCRIPT_DIR/example-cards/$DATE-card.json"
  local url
  if url="$(extract_notion_url "$card" 2>/dev/null)" && [ -n "$url" ]; then
    open_target "$url"
  else
    echo "ERROR: no Notion URL found in $card" >&2
    return 1
  fi
}

handle_dir() {
  open_target "$LOG_DIR"
}

case "$WHAT" in
  log)      handle_log ;;
  card)     handle_card ;;
  obsidian) handle_obsidian ;;
  notion)   handle_notion ;;
  dir)      handle_dir ;;
  all)
    ec=0
    handle_log      || ec=1
    handle_card     || ec=1
    handle_obsidian || ec=1
    handle_notion   || ec=1
    exit $ec
    ;;
  *)
    echo "ERROR: --what must be one of: log, card, obsidian, notion, dir, all" >&2
    exit 2 ;;
esac
