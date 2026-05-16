#!/bin/bash
set -euo pipefail

# weekly-digest.sh — Multi-day digest of briefing activity.
# Aggregates the last N days of logs, card.json files, and (if available) eval
# store rows into a single console summary: success rate, engine breakdown,
# top source domains, est. cost, and (optionally) median composite score.
#
# Usage:
#   bash scripts/weekly-digest.sh                # last 7 days
#   bash scripts/weekly-digest.sh --days 14
#   bash scripts/weekly-digest.sh --since 2026-03-01 --until 2026-03-18
#   bash scripts/weekly-digest.sh --top 5        # top N source domains
#   bash scripts/weekly-digest.sh --json

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"

DAYS=7
SINCE=""
UNTIL=""
TOP=10
JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --days)  DAYS="$2";  shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    --top)   TOP="$2";   shift 2 ;;
    --json)  JSON=1;     shift   ;;
    -h|--help)
      sed -n '4,13p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
  G='\033[32m'; R='\033[31m'; Y='\033[33m'; D='\033[90m'; B='\033[1m'; C='\033[36m'; Z='\033[0m'
else
  G=''; R=''; Y=''; D=''; B=''; C=''; Z=''
fi

# Determine date range.
days_ago() {
  local n="$1"
  if date -v-"${n}"d +%Y-%m-%d >/dev/null 2>&1; then
    date -v-"${n}"d +%Y-%m-%d
  else
    date -d "${n} days ago" +%Y-%m-%d
  fi
}

if [ -z "$UNTIL" ]; then UNTIL="$(date +%Y-%m-%d)"; fi
if [ -z "$SINCE" ]; then SINCE="$(days_ago "$((DAYS - 1))")"; fi

[ -d "$LOG_DIR" ] || { echo "No logs directory at $LOG_DIR." >&2; exit 0; }

TOTAL=0; SUCCESS=0; FAILED=0; INCOMPLETE=0
declare -a ENGINE_NAMES=(); declare -a ENGINE_COUNTS=()

bump_engine() {
  local cli="$1" i
  for i in "${!ENGINE_NAMES[@]}"; do
    if [ "${ENGINE_NAMES[$i]}" = "$cli" ]; then
      ENGINE_COUNTS[$i]=$((ENGINE_COUNTS[$i] + 1)); return
    fi
  done
  ENGINE_NAMES+=("$cli"); ENGINE_COUNTS+=(1)
}

LOG_FILES=()
while IFS= read -r f; do LOG_FILES+=("$f"); done < <(
  find "$LOG_DIR" -maxdepth 1 -type f -name '*.log' 2>/dev/null |
    grep -E '/[0-9]{4}-[0-9]{2}-[0-9]{2}\.log$' |
    sort
)

CARD_FILES=()
for log in "${LOG_FILES[@]}"; do
  date_part="$(basename "$log" .log)"
  [[ "$date_part" < "$SINCE" ]] && continue
  [[ "$date_part" > "$UNTIL" ]] && continue

  TOTAL=$((TOTAL + 1))
  if grep -q "Briefing complete" "$log" 2>/dev/null; then
    SUCCESS=$((SUCCESS + 1))
    # Note: trailing `|| true` keeps `set -e` from tripping when grep finds nothing.
    engine="$(grep -Eo 'Engine: [a-z]+' "$log" 2>/dev/null | tail -1 | awk '{print $2}' || true)"
    [ -n "$engine" ] && bump_engine "$engine"
  elif grep -q "Briefing FAILED" "$log" 2>/dev/null; then
    FAILED=$((FAILED + 1))
  else
    INCOMPLETE=$((INCOMPLETE + 1))
  fi

  card="$LOG_DIR/${date_part}-card.json"
  [ -f "$card" ] && CARD_FILES+=("$card")
done

# Top source domains from card.json files.
TOP_DOMAINS=""
if [ "${#CARD_FILES[@]}" -gt 0 ] && command -v python3 >/dev/null 2>&1; then
  TOP_DOMAINS="$(python3 - "$TOP" "${CARD_FILES[@]}" <<'PY'
import json, re, sys
from collections import Counter
from urllib.parse import urlparse

top_n = int(sys.argv[1])
files = sys.argv[2:]
counter = Counter()

def walk(node):
    if isinstance(node, dict):
        if node.get("type") == "TextBlock":
            yield node.get("text", "") or ""
        for key in ("items", "columns", "body"):
            for child in node.get(key, []) or []:
                yield from walk(child)
    elif isinstance(node, list):
        for child in node:
            yield from walk(child)

url_re = re.compile(r"https?://[^\s)\]]+", re.I)
for path in files:
    try:
        with open(path, "r", encoding="utf-8") as f:
            card = json.load(f)
    except Exception:
        continue
    content = card
    if isinstance(content, dict) and "attachments" in content:
        atts = content.get("attachments") or []
        if atts and isinstance(atts[0], dict):
            content = atts[0].get("content", {})
    for text in walk(content):
        for url in url_re.findall(text or ""):
            url = url.rstrip(".,);]")
            try:
                host = urlparse(url).netloc.lower()
                host = host[4:] if host.startswith("www.") else host
                if host:
                    counter[host] += 1
            except Exception:
                pass

for host, n in counter.most_common(top_n):
    print(f"{n}\t{host}")
PY
)"
fi

# Eval composite for the window (if store exists).
EVAL_MEDIAN=""
EVAL_COUNT=0
if [ -f "$SCRIPT_DIR/eval/store.sqlite" ] && command -v sqlite3 >/dev/null 2>&1; then
  EVAL_COUNT=$(sqlite3 "$SCRIPT_DIR/eval/store.sqlite" \
    "SELECT COUNT(*) FROM eval_runs WHERE card_date BETWEEN '$SINCE' AND '$UNTIL';" 2>/dev/null || echo 0)
  if [ "$EVAL_COUNT" -gt 0 ]; then
    EVAL_MEDIAN=$(sqlite3 "$SCRIPT_DIR/eval/store.sqlite" "
      SELECT printf('%.2f', composite) FROM eval_runs
      WHERE card_date BETWEEN '$SINCE' AND '$UNTIL'
      ORDER BY composite
      LIMIT 1 OFFSET (SELECT COUNT(*)/2 FROM eval_runs WHERE card_date BETWEEN '$SINCE' AND '$UNTIL');
    " 2>/dev/null || echo "")
  fi
fi

# Cost estimate (uses same envelope as cost-report.sh).
EST_LOW=0; EST_AVG=0; EST_HIGH=0
if [ "$SUCCESS" -gt 0 ] && command -v bc >/dev/null 2>&1; then
  EST_LOW=$(echo "$SUCCESS * 0.70" | bc 2>/dev/null || echo 0)
  EST_AVG=$(echo "$SUCCESS * 1.05" | bc 2>/dev/null || echo 0)
  EST_HIGH=$(echo "$SUCCESS * 1.40" | bc 2>/dev/null || echo 0)
fi

if [ "$JSON" -eq 1 ]; then
  printf '{\n  "since": "%s",\n  "until": "%s",\n  "totals": {"runs": %d, "success": %d, "failed": %d, "incomplete": %d},\n' \
    "$SINCE" "$UNTIL" "$TOTAL" "$SUCCESS" "$FAILED" "$INCOMPLETE"
  printf '  "engines": {'
  for i in "${!ENGINE_NAMES[@]}"; do
    sep=","; [ "$i" -eq $((${#ENGINE_NAMES[@]} - 1)) ] && sep=""
    printf '"%s": %d%s' "${ENGINE_NAMES[$i]}" "${ENGINE_COUNTS[$i]}" "$sep"
  done
  printf '},\n  "eval": {"rows": %d, "median_composite": "%s"},\n' "$EVAL_COUNT" "$EVAL_MEDIAN"
  printf '  "cost_estimate_usd": {"low": "%s", "avg": "%s", "high": "%s"},\n' "$EST_LOW" "$EST_AVG" "$EST_HIGH"
  printf '  "top_domains": ['
  if [ -n "$TOP_DOMAINS" ]; then
    first=1
    while IFS=$'\t' read -r n host; do
      [ -z "$host" ] && continue
      [ "$first" -eq 0 ] && printf ','
      printf '{"host":"%s","count":%s}' "$host" "$n"
      first=0
    done <<<"$TOP_DOMAINS"
  fi
  printf ']\n}\n'
  exit 0
fi

echo ""
printf "  ${B}AI News Briefing — weekly digest${Z}\n"
echo "  ====================================="
printf "  %-22s %s -> %s\n" "window:"   "$SINCE" "$UNTIL"
printf "  %-22s %d run(s)\n"            "scanned:" "$TOTAL"
echo ""

if [ "$TOTAL" -eq 0 ]; then
  printf "  ${D}No briefing logs in window.${Z}\n\n"
  exit 0
fi

printf "  ${C}Runs${Z}\n"
printf "    %-20s ${G}%d${Z}\n" "succeeded:"  "$SUCCESS"
printf "    %-20s ${R}%d${Z}\n" "failed:"     "$FAILED"
printf "    %-20s ${D}%d${Z}\n" "incomplete:" "$INCOMPLETE"

if [ "$TOTAL" -gt 0 ] && command -v awk >/dev/null 2>&1; then
  RATE=$(awk -v s="$SUCCESS" -v t="$TOTAL" 'BEGIN { printf "%.0f", (s/t)*100 }')
  printf "    %-20s %s%%\n" "success rate:" "$RATE"
fi
echo ""

if [ "${#ENGINE_NAMES[@]}" -gt 0 ]; then
  printf "  ${C}Engines used${Z}\n"
  for i in "${!ENGINE_NAMES[@]}"; do
    printf "    %-20s %d\n" "${ENGINE_NAMES[$i]}" "${ENGINE_COUNTS[$i]}"
  done
  echo ""
fi

if [ "$EVAL_COUNT" -gt 0 ]; then
  printf "  ${C}Eval composite${Z}\n"
  printf "    %-20s %s   (%d row(s) in store)\n" "median:" "${EVAL_MEDIAN:-n/a}" "$EVAL_COUNT"
  echo ""
fi

if [ "$SUCCESS" -gt 0 ]; then
  printf "  ${C}Cost estimate${Z}  (sonnet envelope)\n"
  printf "    %-20s \$%s — \$%s — \$%s (low / avg / high)\n" "for ${SUCCESS} run(s):" "$EST_LOW" "$EST_AVG" "$EST_HIGH"
  echo ""
fi

if [ -n "$TOP_DOMAINS" ]; then
  printf "  ${C}Top source domains${Z}  (top $TOP)\n"
  awk -F'\t' '{ printf "    %5d  %s\n", $1, $2 }' <<<"$TOP_DOMAINS"
  echo ""
fi

printf "  ${D}Tip: bash scripts/weekly-digest.sh --days 30 --top 20${Z}\n"
echo ""
