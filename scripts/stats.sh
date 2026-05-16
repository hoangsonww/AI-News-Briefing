#!/bin/bash
set -euo pipefail

# stats.sh — At-a-glance project state: file counts, LOC, plugins, eval rows,
# logs, golden cards, example cards. Pure read-only.
#
# Usage:
#   bash scripts/stats.sh                # default human-readable table
#   bash scripts/stats.sh --json         # machine-readable JSON

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    -h|--help)
      sed -n '4,9p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
  G='\033[32m'; D='\033[90m'; B='\033[1m'; C='\033[36m'; Z='\033[0m'
else
  G=''; D=''; B=''; C=''; Z=''
fi

count_files() {
  # count_files <dir> <pattern>
  local dir="$1" pat="$2"
  [ -d "$dir" ] || { echo 0; return; }
  find "$dir" -type f -name "$pat" 2>/dev/null | wc -l | tr -d ' '
}

count_loc() {
  # Sum of line counts for the given glob. Files passed via find -print0.
  local dir="$1" pat="$2"
  [ -d "$dir" ] || { echo 0; return; }
  local total=0
  while IFS= read -r -d '' f; do
    n=$(wc -l <"$f" 2>/dev/null || echo 0)
    total=$((total + n))
  done < <(find "$dir" -type f -name "$pat" -print0 2>/dev/null)
  echo "$total"
}

human_bytes() {
  # Convert a byte count to a human string (B/KB/MB/GB).
  local n="${1:-0}"
  awk -v n="$n" 'BEGIN {
    s = "B KB MB GB TB"; split(s, u, " "); i = 1
    while (n >= 1024 && i < 5) { n = n / 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), n, u[i]
  }'
}

dir_size_bytes() {
  local d="$1"
  [ -d "$d" ] || { echo 0; return; }
  # Portable across macOS (BSD du) and Linux (GNU du).
  if du -sk "$d" >/dev/null 2>&1; then
    du -sk "$d" 2>/dev/null | awk '{print $1 * 1024}'
  else
    echo 0
  fi
}

# ---- Collect ---------------------------------------------------------------
SH_COUNT=$(count_files . '*.sh')
PS1_COUNT=$(count_files . '*.ps1')
PY_COUNT=$(count_files . '*.py')
MD_COUNT=$(count_files . '*.md')

SH_LOC=$(count_loc . '*.sh')
PS1_LOC=$(count_loc . '*.ps1')
PY_LOC=$(count_loc . '*.py')
MD_LOC=$(count_loc . '*.md')

SCRIPTS_SH=$(count_files scripts '*.sh')
SCRIPTS_PS1=$(count_files scripts '*.ps1')

CLAUDE_PLUGINS=0
CODEX_PLUGINS=0
GEMINI_PLUGINS=0
[ -d claude-plugins ]      && CLAUDE_PLUGINS=$(find claude-plugins -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
[ -d plugins ]             && CODEX_PLUGINS=$(find plugins -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
[ -d gemini-extensions ]   && GEMINI_PLUGINS=$(find gemini-extensions -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')

# Only hand `find` directories that exist — a missing arg makes it exit
# non-zero, which with `pipefail` + `set -e` would kill the script.
PLUGIN_DIRS=()
for d in claude-plugins plugins gemini-extensions; do
  [ -d "$d" ] && PLUGIN_DIRS+=("$d")
done
SKILL_COUNT=0
AGENT_COUNT=0
if [ "${#PLUGIN_DIRS[@]}" -gt 0 ]; then
  SKILL_COUNT=$(find "${PLUGIN_DIRS[@]}" -type f -name 'SKILL.md' 2>/dev/null | wc -l | tr -d ' ')
  AGENT_COUNT=$(find "${PLUGIN_DIRS[@]}" -type f -path '*/agents/*.md' 2>/dev/null | wc -l | tr -d ' ')
fi

LOG_COUNT=0
CARD_LOG_COUNT=0
if [ -d logs ]; then
  LOG_COUNT=$(find logs -maxdepth 1 -type f -name '*.log' 2>/dev/null | wc -l | tr -d ' ')
  CARD_LOG_COUNT=$(find logs -maxdepth 1 -type f -name '*-card.json' 2>/dev/null | wc -l | tr -d ' ')
fi
LOG_BYTES=$(dir_size_bytes logs)
EXAMPLE_CARDS=$(count_files example-cards '*.json')
GOLDEN_CARDS=$(count_files eval/golden '*.json')

EVAL_ROWS=0
EVAL_JUDGES=0
EVAL_DATE_MIN=""
EVAL_DATE_MAX=""
if [ -f eval/store.sqlite ] && command -v sqlite3 >/dev/null 2>&1; then
  EVAL_ROWS=$(sqlite3 eval/store.sqlite "SELECT COUNT(*) FROM eval_runs;" 2>/dev/null || echo 0)
  EVAL_JUDGES=$(sqlite3 eval/store.sqlite "SELECT COUNT(DISTINCT judge_model) FROM eval_runs;" 2>/dev/null || echo 0)
  EVAL_DATE_MIN=$(sqlite3 eval/store.sqlite "SELECT MIN(card_date) FROM eval_runs;" 2>/dev/null || echo "")
  EVAL_DATE_MAX=$(sqlite3 eval/store.sqlite "SELECT MAX(card_date) FROM eval_runs;" 2>/dev/null || echo "")
fi

if command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1; then
  GIT_COMMITS=$(git rev-list --count HEAD 2>/dev/null || echo 0)
  GIT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  GIT_LAST=$(git log -1 --format='%h %ad %s' --date=short 2>/dev/null || echo "")
else
  GIT_COMMITS=0; GIT_BRANCH=""; GIT_LAST=""
fi

# ---- Emit ------------------------------------------------------------------
if [ "$JSON" -eq 1 ]; then
  printf '{\n'
  printf '  "files":   {"sh": %d, "ps1": %d, "py": %d, "md": %d},\n' "$SH_COUNT" "$PS1_COUNT" "$PY_COUNT" "$MD_COUNT"
  printf '  "loc":     {"sh": %d, "ps1": %d, "py": %d, "md": %d},\n' "$SH_LOC" "$PS1_LOC" "$PY_LOC" "$MD_LOC"
  printf '  "scripts": {"sh": %d, "ps1": %d},\n' "$SCRIPTS_SH" "$SCRIPTS_PS1"
  printf '  "plugins": {"claude": %d, "codex": %d, "gemini": %d, "skills": %d, "agents": %d},\n' \
    "$CLAUDE_PLUGINS" "$CODEX_PLUGINS" "$GEMINI_PLUGINS" "$SKILL_COUNT" "$AGENT_COUNT"
  printf '  "logs":    {"count": %d, "cards": %d, "bytes": %d},\n' "$LOG_COUNT" "$CARD_LOG_COUNT" "$LOG_BYTES"
  printf '  "cards":   {"example": %d, "golden": %d},\n' "$EXAMPLE_CARDS" "$GOLDEN_CARDS"
  printf '  "eval":    {"rows": %d, "judges": %d, "from": "%s", "to": "%s"},\n' \
    "$EVAL_ROWS" "$EVAL_JUDGES" "$EVAL_DATE_MIN" "$EVAL_DATE_MAX"
  printf '  "git":     {"commits": %d, "branch": "%s", "last": "%s"}\n' "$GIT_COMMITS" "$GIT_BRANCH" "${GIT_LAST//\"/\\\"}"
  printf '}\n'
  exit 0
fi

echo ""
printf "  ${B}AI News Briefing — project stats${Z}\n"
echo "  ================================="
echo ""
printf "  ${C}Source${Z}\n"
printf "    %-18s %5d files  %6d LOC\n" "shell (.sh)"      "$SH_COUNT"  "$SH_LOC"
printf "    %-18s %5d files  %6d LOC\n" "powershell (.ps1)" "$PS1_COUNT" "$PS1_LOC"
printf "    %-18s %5d files  %6d LOC\n" "python (.py)"     "$PY_COUNT"  "$PY_LOC"
printf "    %-18s %5d files  %6d LOC\n" "markdown (.md)"   "$MD_COUNT"  "$MD_LOC"
echo ""
printf "  ${C}scripts/${Z}\n"
printf "    %-18s %5d\n" ".sh pairs"  "$SCRIPTS_SH"
printf "    %-18s %5d\n" ".ps1 pairs" "$SCRIPTS_PS1"
echo ""
printf "  ${C}Plugin ecosystem${Z}\n"
printf "    %-18s %5d\n" "Claude plugins" "$CLAUDE_PLUGINS"
printf "    %-18s %5d\n" "Codex plugins"  "$CODEX_PLUGINS"
printf "    %-18s %5d\n" "Gemini exts"    "$GEMINI_PLUGINS"
printf "    %-18s %5d\n" "SKILL.md files" "$SKILL_COUNT"
printf "    %-18s %5d\n" "agent files"    "$AGENT_COUNT"
echo ""
printf "  ${C}Briefings${Z}\n"
printf "    %-18s %5d files   (%s on disk)\n" "logs/*.log"      "$LOG_COUNT" "$(human_bytes "$LOG_BYTES")"
printf "    %-18s %5d files\n"                 "logs/*-card.json" "$CARD_LOG_COUNT"
printf "    %-18s %5d files\n"                 "example-cards/"   "$EXAMPLE_CARDS"
echo ""
printf "  ${C}Eval harness${Z}\n"
if [ "$EVAL_ROWS" -gt 0 ]; then
  printf "    %-18s %5d rows   (%d judge%s)\n" "store.sqlite" "$EVAL_ROWS" "$EVAL_JUDGES" "$([ "$EVAL_JUDGES" = "1" ] && echo "" || echo "s")"
  printf "    %-18s %s -> %s\n" "date range" "${EVAL_DATE_MIN:-?}" "${EVAL_DATE_MAX:-?}"
else
  printf "    %-18s ${D}empty (run: make eval-backfill)${Z}\n" "store.sqlite"
fi
printf "    %-18s %5d files\n" "golden cards" "$GOLDEN_CARDS"
echo ""
if [ -n "$GIT_BRANCH" ]; then
  printf "  ${C}Git${Z}\n"
  printf "    %-18s %s\n"     "branch"       "$GIT_BRANCH"
  printf "    %-18s %d\n"     "commits"      "$GIT_COMMITS"
  printf "    %-18s %s\n"     "latest"       "${GIT_LAST:-?}"
  echo ""
fi

printf "  ${D}Tip: bash scripts/stats.sh --json   # machine-readable${Z}\n"
echo ""
