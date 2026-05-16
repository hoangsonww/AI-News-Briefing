#!/bin/bash
set -euo pipefail

# topic-stats.sh — Tally [[wikilink]] topic mentions across published briefings.
# Scans logs/*-obsidian.md by default. Pass --vault to also include files in
# the configured Obsidian vault ($AI_BRIEFING_OBSIDIAN_VAULT). Useful for
# spotting which topics dominate over the last N days.
#
# Usage:
#   bash scripts/topic-stats.sh                       # default top 20 from logs/
#   bash scripts/topic-stats.sh --top 50
#   bash scripts/topic-stats.sh --since 2026-03-01
#   bash scripts/topic-stats.sh --vault               # also scan AI_BRIEFING_OBSIDIAN_VAULT
#   bash scripts/topic-stats.sh --vault-only          # only scan the vault
#   bash scripts/topic-stats.sh --json

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"

TOP=20
SINCE=""
UNTIL=""
INCLUDE_VAULT=0
VAULT_ONLY=0
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --top)        TOP="$2"; shift 2 ;;
    --since)      SINCE="$2"; shift 2 ;;
    --until)      UNTIL="$2"; shift 2 ;;
    --vault)      INCLUDE_VAULT=1; shift ;;
    --vault-only) INCLUDE_VAULT=1; VAULT_ONLY=1; shift ;;
    --json)       JSON=1; shift ;;
    -h|--help)
      sed -n '4,14p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
  G='\033[32m'; D='\033[90m'; B='\033[1m'; C='\033[36m'; Z='\033[0m'
else
  G=''; D=''; B=''; C=''; Z=''
fi

FILES=()

if [ "$VAULT_ONLY" -eq 0 ] && [ -d "$LOG_DIR" ]; then
  while IFS= read -r -d '' f; do
    base="$(basename "$f")"
    # Filter by date if SINCE/UNTIL set.
    if [[ "$base" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})-obsidian\.md$ ]]; then
      d="${BASH_REMATCH[1]}"
      [ -n "$SINCE" ] && [[ "$d" < "$SINCE" ]] && continue
      [ -n "$UNTIL" ] && [[ "$d" > "$UNTIL" ]] && continue
    fi
    FILES+=("$f")
  done < <(find "$LOG_DIR" -maxdepth 1 -type f -name '*-obsidian.md' -print0 2>/dev/null)
fi

if [ "$INCLUDE_VAULT" -eq 1 ]; then
  VAULT="${AI_BRIEFING_OBSIDIAN_VAULT:-}"
  if [ -z "$VAULT" ]; then
    echo "WARN: AI_BRIEFING_OBSIDIAN_VAULT not set; --vault flag ignored." >&2
  elif [ ! -d "$VAULT" ]; then
    echo "WARN: vault path does not exist: $VAULT" >&2
  else
    while IFS= read -r -d '' f; do FILES+=("$f"); done < <(find "$VAULT" -type f -name '*.md' -print0 2>/dev/null)
  fi
fi

if [ "${#FILES[@]}" -eq 0 ]; then
  if [ "$JSON" -eq 1 ]; then
    printf '{"files": 0, "topics": []}\n'
  else
    echo ""
    printf "  ${D}No markdown files found to scan.${Z}\n"
    echo ""
  fi
  exit 0
fi

# Extract [[wikilink]] occurrences, normalize "Topic|alias" to just "Topic".
COUNTS="$(grep -hoE '\[\[[^]|]+(\|[^]]*)?\]\]' "${FILES[@]}" 2>/dev/null |
          sed -E 's/^\[\[//; s/\]\]$//; s/\|.*$//' |
          awk 'NF' |
          sort |
          uniq -c |
          sort -rn |
          head -n "$TOP")"

TOTAL_LINKS=$(grep -hoE '\[\[[^]|]+(\|[^]]*)?\]\]' "${FILES[@]}" 2>/dev/null | wc -l | tr -d ' ')
UNIQUE_LINKS=$(grep -hoE '\[\[[^]|]+(\|[^]]*)?\]\]' "${FILES[@]}" 2>/dev/null |
               sed -E 's/^\[\[//; s/\]\]$//; s/\|.*$//' | awk 'NF' | sort -u | wc -l | tr -d ' ')

if [ "$JSON" -eq 1 ]; then
  printf '{\n  "files": %d,\n  "total_links": %d,\n  "unique_topics": %d,\n  "topics": [\n' \
    "${#FILES[@]}" "$TOTAL_LINKS" "$UNIQUE_LINKS"
  first=1
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    n=$(echo "$line" | awk '{print $1}')
    topic=$(echo "$line" | sed -E 's/^ *[0-9]+ +//')
    [ "$first" -eq 0 ] && printf ',\n'
    pj="$(printf '%s' "$topic" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || printf '"%s"' "$topic")"
    printf '    {"topic": %s, "count": %s}' "$pj" "$n"
    first=0
  done <<<"$COUNTS"
  printf '\n  ]\n}\n'
  exit 0
fi

echo ""
printf "  ${B}Topic frequency${Z}  (top $TOP)\n"
echo "  ============================================="
printf "  %-22s %d\n" "files scanned:"   "${#FILES[@]}"
printf "  %-22s %d\n" "total wikilinks:" "$TOTAL_LINKS"
printf "  %-22s %d\n" "unique topics:"   "$UNIQUE_LINKS"
[ -n "$SINCE" ] || [ -n "$UNTIL" ] && printf "  %-22s %s -> %s\n" "date range:" "${SINCE:-(start)}" "${UNTIL:-(end)}"
echo ""

if [ -z "$COUNTS" ]; then
  printf "  ${D}No wikilinks found.${Z}\n\n"
  exit 0
fi

printf "  ${C}%5s  %s${Z}\n" "count" "topic"
printf "  %5s  %s\n"          "-----" "-----"
while IFS= read -r line; do
  [ -z "$line" ] && continue
  n=$(echo "$line"     | awk '{print $1}')
  topic=$(echo "$line" | sed -E 's/^ *[0-9]+ +//')
  printf "  ${G}%5s${Z}  %s\n" "$n" "$topic"
done <<<"$COUNTS"
echo ""
