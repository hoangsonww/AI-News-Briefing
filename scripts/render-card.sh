#!/bin/bash
set -euo pipefail

# render-card.sh — Pretty-print a daily card.json in the terminal.
# Walks the Adaptive Card body: emphasis containers become section headers,
# inline `**Bold**` TextBlocks become topic sub-headers, leading "- " bullets
# stay as bullets, and the Action.OpenUrl is shown as a "View" hint at the end.
#
# Usage:
#   bash scripts/render-card.sh                       # today's card from logs/
#   bash scripts/render-card.sh --date 2026-03-18     # specific date in logs/
#   bash scripts/render-card.sh --file path/to.json   # any file
#   bash scripts/render-card.sh --example 2026-03-18  # example-cards/<date>-card.json
#   bash scripts/render-card.sh --no-color            # plain output for piping

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

DATE="$(date +%Y-%m-%d)"
FILE=""
USE_EXAMPLE=0
NO_COLOR=0

while [ $# -gt 0 ]; do
  case "$1" in
    --date)    DATE="$2"; shift 2 ;;
    --file)    FILE="$2"; shift 2 ;;
    --example) USE_EXAMPLE=1; DATE="$2"; shift 2 ;;
    --no-color) NO_COLOR=1; shift ;;
    -h|--help)
      sed -n '4,14p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$FILE" ]; then
  if [ "$USE_EXAMPLE" -eq 1 ]; then
    FILE="$SCRIPT_DIR/example-cards/$DATE-card.json"
  else
    FILE="$SCRIPT_DIR/logs/$DATE-card.json"
  fi
fi

if [ ! -f "$FILE" ]; then
  echo "ERROR: card file not found: $FILE" >&2
  if [ "$USE_EXAMPLE" -eq 0 ]; then
    echo "Try: bash scripts/render-card.sh --example $DATE" >&2
  fi
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required to parse Adaptive Card JSON." >&2
  exit 2
fi

if [ -t 1 ] && [ "$NO_COLOR" -eq 0 ]; then
  USE_COLOR=1
else
  USE_COLOR=0
fi

USE_COLOR="$USE_COLOR" python3 - "$FILE" <<'PY'
import json, os, sys, re

path = sys.argv[1]
use_color = os.environ.get("USE_COLOR", "0") == "1"

def C(code, s):
    return f"\033[{code}m{s}\033[0m" if use_color else s

def bold(s):    return C("1", s)
def cyan(s):    return C("36", s)
def green(s):   return C("32", s)
def yellow(s):  return C("33", s)
def dim(s):     return C("90", s)
def magenta(s): return C("35", s)

try:
    with open(path, "r", encoding="utf-8") as f:
        card = json.load(f)
except Exception as e:
    print(f"ERROR: invalid JSON in {path}: {e}", file=sys.stderr)
    sys.exit(2)

# Drill into the Adaptive Card content.
content = card
if isinstance(content, dict) and "attachments" in content:
    atts = content.get("attachments") or []
    if atts and isinstance(atts[0], dict):
        content = atts[0].get("content", {})

body    = content.get("body", []) if isinstance(content, dict) else []
actions = content.get("actions", []) if isinstance(content, dict) else []

def walk_textblocks(node):
    """Yield TextBlock dicts in order, recursing into containers/columns."""
    if isinstance(node, dict):
        t = node.get("type")
        if t == "TextBlock":
            yield node
        for key in ("items", "columns", "body"):
            for child in node.get(key, []) or []:
                yield from walk_textblocks(child)
    elif isinstance(node, list):
        for child in node:
            yield from walk_textblocks(child)

def strip_md_bold(text):
    return re.sub(r"\*\*(.+?)\*\*", r"\1", text or "")

print()
title = "AI Daily Briefing"
subtitle = ""
right_count = ""
right_topics = ""

# Header detection: first emphasis Container with two TextBlocks per column.
header_blocks = []
if body and isinstance(body[0], dict) and body[0].get("type") == "Container":
    header_blocks = list(walk_textblocks(body[0]))

if header_blocks:
    if len(header_blocks) >= 1: title    = strip_md_bold(header_blocks[0].get("text", title))
    if len(header_blocks) >= 2: subtitle = strip_md_bold(header_blocks[1].get("text", ""))
    if len(header_blocks) >= 3: right_count  = strip_md_bold(header_blocks[2].get("text", ""))
    if len(header_blocks) >= 4: right_topics = strip_md_bold(header_blocks[3].get("text", ""))

left  = f"  {bold(cyan(title))}"
if subtitle: left += "  " + dim(subtitle)
right = ""
if right_count or right_topics:
    right = f"{bold(right_count)}  {dim(right_topics)}" if right_topics else bold(right_count)
print(left + ("   " + right if right else ""))
print("  " + dim("=" * 60))

# Walk remaining containers/blocks after the first (header) container.
def is_emphasis_container(n):
    return (isinstance(n, dict)
            and n.get("type") == "Container"
            and n.get("style") in ("emphasis",))

def is_section_header_text(n):
    # Style 1: an emphasis Container that wraps a single bolded TextBlock — Sources block etc.
    if is_emphasis_container(n):
        return True
    # Style 2: a non-emphasis Container with a single bolded TextBlock — topic headers.
    if isinstance(n, dict) and n.get("type") == "Container":
        tbs = list(walk_textblocks(n))
        if len(tbs) == 1 and "**" in (tbs[0].get("text") or ""):
            return True
    return False

skipped_header = False
for node in body:
    if not skipped_header and isinstance(node, dict) and node.get("type") == "Container":
        skipped_header = True
        continue

    if isinstance(node, dict) and node.get("type") == "Container":
        # New section
        tbs = list(walk_textblocks(node))
        label = strip_md_bold((tbs[0].get("text") if tbs else "") or "")
        print()
        if node.get("style") == "emphasis":
            print(f"  {magenta(bold(label))}")
        else:
            print(f"  {cyan(bold(label))}")
        # Render any additional text inside the container.
        for tb in tbs[1:]:
            txt = strip_md_bold(tb.get("text", ""))
            if txt:
                print(f"    {txt}")
    elif isinstance(node, dict) and node.get("type") == "TextBlock":
        txt = strip_md_bold(node.get("text", ""))
        if not txt:
            continue
        if txt.startswith("- "):
            print(f"    {dim('•')} {txt[2:]}")
        else:
            print(f"    {txt}")

if actions:
    print()
    print("  " + dim("─" * 60))
    for a in actions:
        if isinstance(a, dict) and a.get("type") == "Action.OpenUrl":
            title_a = a.get("title", "Open")
            url     = a.get("url", "")
            print(f"  {green('→')} {bold(title_a)}: {url}")

print()
PY
