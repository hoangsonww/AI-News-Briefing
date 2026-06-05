#!/bin/bash
set -euo pipefail

# validate-card.sh -- Lint a generated Teams/Slack Adaptive Card before delivery.
#
# Catches the failure classes that have bitten this pipeline:
#   - placeholder Notion URL (button points at "notion.so/" or a slug, not a page)
#   - malformed / oversized card (Teams rejects > 28KB)
#   - missing Sources container or the required action button
#   - multiple bullets crammed into one TextBlock (renders on one line in Teams)
#
# Read-only. No network. Exit 0 if the card passes, 1 if any check FAILs.
#
# Usage:
#   ./scripts/validate-card.sh                          # today's logs/DATE-card.json
#   ./scripts/validate-card.sh --card-file path/to.json
#   ./scripts/validate-card.sh logs/2026-06-03-card.json

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATE=$(date +%Y-%m-%d)
CARD_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --card-file) CARD_FILE="$2"; shift 2 ;;
    -h|--help)
      grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 1 ;;
    *) CARD_FILE="$1"; shift ;;
  esac
done

[[ -z "$CARD_FILE" ]] && CARD_FILE="$SCRIPT_DIR/logs/$DATE-card.json"

if [[ ! -f "$CARD_FILE" ]]; then
  echo "FAIL: card file not found: $CARD_FILE" >&2
  exit 1
fi

CARD_FILE="$CARD_FILE" python3 <<'PY'
import json, os, re, sys

path = os.environ["CARD_FILE"]
fails, warns, oks = [], [], []

raw = open(path, "rb").read()
size = len(raw)

# 1. Valid JSON
try:
    card = json.loads(raw)
except Exception as e:
    print(f"FAIL: not valid JSON: {e}")
    print("\nValidation FAILED (1 error).")
    sys.exit(1)
oks.append("valid JSON")

# 2. Size (Teams hard limit 28KB; keep 4KB headroom)
if size > 28 * 1024:
    fails.append(f"size {size}B exceeds Teams 28KB hard limit")
elif size > 24 * 1024:
    warns.append(f"size {size}B over 24KB headroom (Teams limit 28KB)")
else:
    oks.append(f"size {size}B within budget")

# Locate the adaptive card content + flatten all TextBlocks
def walk(node, blocks):
    if isinstance(node, dict):
        if node.get("type") == "TextBlock" and isinstance(node.get("text"), str):
            blocks.append(node["text"])
        for v in node.values():
            walk(v, blocks)
    elif isinstance(node, list):
        for v in node:
            walk(v, blocks)

texts = []
walk(card, texts)
try:
    content = card["attachments"][0]["content"]
    actions = content.get("actions", [])
except Exception:
    actions = []
    fails.append("missing attachments[0].content (not a Teams message card)")

# 3. Action button: exact required title
btn = next((a for a in actions if a.get("type") == "Action.OpenUrl"), None)
if not btn:
    fails.append('missing Action.OpenUrl button')
else:
    if btn.get("title") != "Open Full Briefing in Notion":
        fails.append(f'action title is {btn.get("title")!r}, expected "Open Full Briefing in Notion"')
    else:
        oks.append("action button title correct")

    # 4. Notion URL must be a real page, not a placeholder
    url = (btn.get("url") or "").strip()
    real = re.match(r"^https://(www\.|app\.)?notion\.(so|com)/[^/\s]*[0-9a-fA-F]{32}", url.replace("-", ""))
    placeholder = (
        url in ("", "https://www.notion.so/", "https://www.notion.so")
        or "PAGE_ID" in url
        or url.rstrip("/").endswith("-AI-Daily-Briefing")
    )
    if placeholder or not real:
        fails.append(f"Notion button URL looks like a placeholder, not a real page: {url!r}")
    else:
        oks.append("Notion button URL points at a real page")

# 5. Sources container present
if any("**Sources**" in t for t in texts):
    oks.append("Sources section present")
else:
    fails.append("no Sources section found")

# 6. Header date not left as template placeholder
if any("MONTH DAY, YEAR" in t for t in texts):
    fails.append('header date still the template placeholder "MONTH DAY, YEAR"')

# 7. One bullet per TextBlock (Teams renders multi-bullet blocks on one line)
crammed = [t for t in texts if t.count("\n\n- ") >= 1 or "•" in t]
if crammed:
    warns.append(f"{len(crammed)} TextBlock(s) appear to cram multiple bullets (use one TextBlock per bullet)")
else:
    oks.append("bullets are one-per-TextBlock")

# Report
print(f"Validating: {path}")
for m in oks:
    print(f"  PASS  {m}")
for m in warns:
    print(f"  WARN  {m}")
for m in fails:
    print(f"  FAIL  {m}")

print()
if fails:
    print(f"Validation FAILED ({len(fails)} error(s), {len(warns)} warning(s)).")
    sys.exit(1)
print(f"Validation passed ({len(warns)} warning(s)).")
PY
