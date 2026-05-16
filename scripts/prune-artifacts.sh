#!/bin/bash
set -euo pipefail

# prune-artifacts.sh — Clean up orphaned briefing artifacts in logs/.
#
# An artifact is considered "orphaned" when the corresponding date's .log file
# is missing. We scan for these artifact families:
#   - YYYY-MM-DD-card.json        (Adaptive Card payloads)
#   - YYYY-MM-DD-obsidian.md      (Obsidian publish source)
#   - YYYY-MM-DD-dry-run.log      (dry-run output)
#   - eval-judge-YYYY-MM-DD.log   (eval auto-judge logs)
#
# By default this is a DRY RUN — pass --apply to actually delete.
#
# Usage:
#   bash scripts/prune-artifacts.sh                      # dry-run, no age filter
#   bash scripts/prune-artifacts.sh --apply              # actually delete
#   bash scripts/prune-artifacts.sh --days 30 --apply    # only delete files >30 days old
#   bash scripts/prune-artifacts.sh --include eval       # also prune eval-judge-*.log orphans
#   bash scripts/prune-artifacts.sh --json               # machine-readable

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"

APPLY=0
DAYS=0
INCLUDE_EVAL=0
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY=1; shift ;;
    --days)    DAYS="$2"; shift 2 ;;
    --include) [ "$2" = "eval" ] && INCLUDE_EVAL=1; shift 2 ;;
    --json)    JSON=1; shift ;;
    -h|--help)
      sed -n '4,21p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
  G='\033[32m'; Y='\033[33m'; D='\033[90m'; B='\033[1m'; Z='\033[0m'
else
  G=''; Y=''; D=''; B=''; Z=''
fi

# A missing logs/ dir is normal on a fresh checkout — treat it as "0 orphans".
# The glob loops below already tolerate it, so just fall through.

# Files we might delete.
ORPHANS=()

is_older_than_days() {
  # is_older_than_days <file> <days>; returns 0 if older OR days==0.
  local f="$1" d="$2"
  [ "$d" -le 0 ] && return 0
  # mtime in seconds since epoch (portable).
  local mtime now age
  if mtime=$(stat -f %m "$f" 2>/dev/null); then :
  else mtime=$(stat -c %Y "$f" 2>/dev/null || echo 0); fi
  now=$(date +%s)
  age=$(( (now - mtime) / 86400 ))
  [ "$age" -ge "$d" ]
}

scan_pair() {
  # scan_pair <suffix> — e.g. "-card.json", "-obsidian.md", "-dry-run.log"
  local suffix="$1"
  local f base date_part log_file
  for f in "$LOG_DIR"/*"$suffix"; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    # Extract date prefix YYYY-MM-DD
    if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
      date_part="${BASH_REMATCH[1]}"
    else
      continue
    fi
    log_file="$LOG_DIR/${date_part}.log"
    if [ ! -f "$log_file" ]; then
      if is_older_than_days "$f" "$DAYS"; then
        ORPHANS+=("$f")
      fi
    fi
  done
}

scan_eval_logs() {
  local f base date_part log_file
  for f in "$LOG_DIR"/eval-judge-*.log; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    if [[ "$base" =~ ^eval-judge-([0-9]{4}-[0-9]{2}-[0-9]{2})\.log$ ]]; then
      date_part="${BASH_REMATCH[1]}"
    else
      continue
    fi
    log_file="$LOG_DIR/${date_part}.log"
    if [ ! -f "$log_file" ]; then
      if is_older_than_days "$f" "$DAYS"; then
        ORPHANS+=("$f")
      fi
    fi
  done
}

scan_pair "-card.json"
scan_pair "-obsidian.md"
scan_pair "-dry-run.log"
[ "$INCLUDE_EVAL" -eq 1 ] && scan_eval_logs

if [ "$JSON" -eq 1 ]; then
  printf '{\n  "dry_run": %s,\n  "days": %d,\n  "count": %d,\n  "files": [' \
    "$([ "$APPLY" -eq 1 ] && echo false || echo true)" "$DAYS" "${#ORPHANS[@]}"
  for i in "${!ORPHANS[@]}"; do
    sep=","; [ "$i" -eq $((${#ORPHANS[@]} - 1)) ] && sep=""
    rel="${ORPHANS[$i]#${SCRIPT_DIR}/}"
    printf '"%s"%s' "$rel" "$sep"
  done
  printf ']\n}\n'
  exit 0
fi

echo ""
printf "  ${B}prune-artifacts${Z}  (mode: %s, age floor: %s)\n" \
  "$([ "$APPLY" -eq 1 ] && printf "${Y}APPLY${Z}" || printf "${G}dry-run${Z}")" \
  "$([ "$DAYS" -gt 0 ] && echo "${DAYS}d" || echo "any")"
echo "  ============================================="

if [ "${#ORPHANS[@]}" -eq 0 ]; then
  printf "  ${G}No orphaned artifacts found.${Z}\n\n"
  exit 0
fi

TOTAL_BYTES=0
for f in "${ORPHANS[@]}"; do
  size=$(wc -c <"$f" 2>/dev/null | tr -d ' ' || echo 0)
  TOTAL_BYTES=$((TOTAL_BYTES + size))
  rel="${f#${SCRIPT_DIR}/}"
  if [ "$APPLY" -eq 1 ]; then
    marker="${Y}DEL${Z}"
  else
    marker="${D} - ${Z}"
  fi
  printf '  %s  %s%6d B%s  %s\n' "$marker" "$D" "$size" "$Z" "$rel"
done

if [ "$APPLY" -eq 1 ]; then
  for f in "${ORPHANS[@]}"; do
    rm -f "$f"
  done
  printf '\n  %sRemoved %d file(s), freed ~%d bytes.%s\n\n' "$G" "${#ORPHANS[@]}" "$TOTAL_BYTES" "$Z"
else
  printf '\n  %sFound %d orphan(s) (~%d bytes). Re-run with --apply to delete.%s\n\n' \
    "$D" "${#ORPHANS[@]}" "$TOTAL_BYTES" "$Z"
fi
