#!/bin/bash
set -euo pipefail

# brief-diff.sh — Show what changed between two days of briefings.
# Extracts topic headers + bullets from each *-card.json into a flat text form,
# then runs `diff -u` (or `delta` if installed). Defaults to yesterday vs today.
#
# Usage:
#   bash scripts/brief-diff.sh                                  # yesterday vs today (logs/)
#   bash scripts/brief-diff.sh --from 2026-03-17 --to 2026-03-18
#   bash scripts/brief-diff.sh --example --from 2026-03-17 --to 2026-03-18
#   bash scripts/brief-diff.sh --plain                          # no color, no delta

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Default: yesterday -> today. Use BSD/GNU date heuristics.
yesterday() {
  if date -v-1d +%Y-%m-%d >/dev/null 2>&1; then
    date -v-1d +%Y-%m-%d
  else
    date -d "yesterday" +%Y-%m-%d
  fi
}

FROM="$(yesterday)"
TO="$(date +%Y-%m-%d)"
SRC_DIR="$SCRIPT_DIR/logs"
PLAIN=0

while [ $# -gt 0 ]; do
  case "$1" in
    --from)    FROM="$2"; shift 2 ;;
    --to)      TO="$2";   shift 2 ;;
    --example) SRC_DIR="$SCRIPT_DIR/example-cards"; shift ;;
    --plain)   PLAIN=1; shift ;;
    -h|--help)
      sed -n '4,12p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

FROM_FILE="$SRC_DIR/$FROM-card.json"
TO_FILE="$SRC_DIR/$TO-card.json"

[ -f "$FROM_FILE" ] || { echo "ERROR: not found: $FROM_FILE" >&2; exit 1; }
[ -f "$TO_FILE" ]   || { echo "ERROR: not found: $TO_FILE"   >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 is required." >&2; exit 2; }

flatten() {
  # Print: lines of the form "## <topic>" and "- <bullet>" extracted from a card.
  python3 - "$1" <<'PY'
import json, re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as f:
    card = json.load(f)

content = card
if isinstance(content, dict) and "attachments" in content:
    atts = content.get("attachments") or []
    if atts and isinstance(atts[0], dict):
        content = atts[0].get("content", {})

body = content.get("body", []) if isinstance(content, dict) else []

def walk(node):
    if isinstance(node, dict):
        if node.get("type") == "TextBlock":
            yield node
        for key in ("items", "columns", "body"):
            for child in node.get(key, []) or []:
                yield from walk(child)
    elif isinstance(node, list):
        for child in node:
            yield from walk(child)

def strip_bold(s): return re.sub(r"\*\*(.+?)\*\*", r"\1", s or "")

# Skip the header container (first Container if it carries the title) — but be tolerant.
seen_header = False
for node in body:
    if not seen_header and isinstance(node, dict) and node.get("type") == "Container":
        # The header container has at least 2 TextBlocks (title+date or counts).
        tbs = list(walk(node))
        if len(tbs) >= 2 and any(("Briefing" in (t.get("text") or "")
                                  or " stories" in (t.get("text") or ""))
                                 for t in tbs):
            seen_header = True
            continue
        seen_header = True  # treat first container as header regardless

    if isinstance(node, dict) and node.get("type") == "Container":
        tbs = list(walk(node))
        if tbs:
            print("## " + strip_bold(tbs[0].get("text", "")).strip())
        for tb in tbs[1:]:
            t = strip_bold(tb.get("text", "")).strip()
            if t:
                line = t[2:] if t.startswith("- ") else t
                print("- " + line)
    elif isinstance(node, dict) and node.get("type") == "TextBlock":
        t = strip_bold(node.get("text", "")).strip()
        if not t:
            continue
        if t.startswith("- "):
            print("- " + t[2:])
        else:
            print(t)
PY
}

TMP_A="$(mktemp -t brief-diff.A.XXXXXX)"
TMP_B="$(mktemp -t brief-diff.B.XXXXXX)"
trap 'rm -f "$TMP_A" "$TMP_B"' EXIT INT TERM

flatten "$FROM_FILE" > "$TMP_A"
flatten "$TO_FILE"   > "$TMP_B"

DIFF_LABEL_A="$FROM"
DIFF_LABEL_B="$TO"

# `diff -u` returns 1 when files differ. That's informational, not a failure,
# so we explicitly succeed and let the user see the output regardless of the
# diff exit code (including through pipes to delta/colordiff under pipefail).
if [ "$PLAIN" -eq 1 ]; then
  diff -u --label "$DIFF_LABEL_A" --label "$DIFF_LABEL_B" "$TMP_A" "$TMP_B" || true
elif command -v delta >/dev/null 2>&1; then
  { diff -u --label "$DIFF_LABEL_A" --label "$DIFF_LABEL_B" "$TMP_A" "$TMP_B" || true; } | delta --paging=never || true
elif [ -t 1 ] && command -v colordiff >/dev/null 2>&1; then
  { diff -u --label "$DIFF_LABEL_A" --label "$DIFF_LABEL_B" "$TMP_A" "$TMP_B" || true; } | colordiff || true
else
  diff -u --label "$DIFF_LABEL_A" --label "$DIFF_LABEL_B" "$TMP_A" "$TMP_B" || true
fi
exit 0
