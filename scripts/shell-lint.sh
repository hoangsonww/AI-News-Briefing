#!/bin/bash
set -euo pipefail

# shell-lint.sh — Lint every shell script in the repo.
# Runs `bash -n` (syntax) on every .sh file, and `shellcheck` if available.
# Skips .git/, node_modules/, and any path containing /vendor/.
#
# Usage:
#   bash scripts/shell-lint.sh                 # lint everything
#   bash scripts/shell-lint.sh --no-shellcheck # skip shellcheck even if installed
#   bash scripts/shell-lint.sh --strict        # fail on shellcheck warnings too
#   bash scripts/shell-lint.sh --path scripts/ # restrict to a subtree
#   bash scripts/shell-lint.sh --json          # machine-readable JSON

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

USE_SHELLCHECK=1
STRICT=0
JSON=0
ROOT="$SCRIPT_DIR"

while [ $# -gt 0 ]; do
  case "$1" in
    --no-shellcheck) USE_SHELLCHECK=0; shift ;;
    --strict)        STRICT=1; shift ;;
    --path)          ROOT="$2"; shift 2 ;;
    --json)          JSON=1; shift ;;
    -h|--help)
      sed -n '4,12p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ] && [ "$JSON" -eq 0 ]; then
  G='\033[32m'; R='\033[31m'; Y='\033[33m'; D='\033[90m'; B='\033[1m'; Z='\033[0m'
else
  G=''; R=''; Y=''; D=''; B=''; Z=''
fi

[ -d "$ROOT" ] || { echo "ERROR: not a directory: $ROOT" >&2; exit 2; }

HAVE_SHELLCHECK=0
if [ "$USE_SHELLCHECK" -eq 1 ] && command -v shellcheck >/dev/null 2>&1; then
  HAVE_SHELLCHECK=1
fi

# Collect .sh files (portable, NUL-delimited to survive spaces).
FILES=()
while IFS= read -r -d '' f; do
  case "$f" in
    */.git/*|*/node_modules/*|*/vendor/*) continue ;;
  esac
  FILES+=("$f")
done < <(find "$ROOT" -type f -name '*.sh' -print0 2>/dev/null)

TOTAL=${#FILES[@]}
SYNTAX_FAILS=0
LINT_FAILS=0
LINT_WARNS=0
FAIL_PATHS=()
WARN_PATHS=()

if [ "$JSON" -eq 0 ]; then
  echo ""
  printf "  ${B}shell-lint${Z}  (%d files under %s)\n" "$TOTAL" "${ROOT#${SCRIPT_DIR}/}"
  echo "  ============================================="
  if [ "$HAVE_SHELLCHECK" -eq 1 ]; then
    printf "  shellcheck: ${G}%s${Z}\n" "$(shellcheck --version | awk '/^version/ {print $2; exit}')"
  else
    printf "  shellcheck: ${D}not installed (skipping)${Z}\n"
  fi
  echo ""
fi

for f in "${FILES[@]}"; do
  rel="${f#${SCRIPT_DIR}/}"

  if ! bash -n "$f" 2>/tmp/shell-lint-err.$$; then
    SYNTAX_FAILS=$((SYNTAX_FAILS + 1))
    FAIL_PATHS+=("$rel")
    if [ "$JSON" -eq 0 ]; then
      printf "  ${R}SYNTAX${Z}  %s\n" "$rel"
      sed 's/^/      /' </tmp/shell-lint-err.$$
    fi
    rm -f /tmp/shell-lint-err.$$
    continue
  fi
  rm -f /tmp/shell-lint-err.$$

  if [ "$HAVE_SHELLCHECK" -eq 1 ]; then
    # SC1091: don't follow source files. SC2155: declare+assign on same line (we use it intentionally).
    if ! out="$(shellcheck -x -e SC1091 -e SC2155 -e SC2034 "$f" 2>&1)"; then
      # ShellCheck flagged at least one issue. Treat error-level as fail; warnings respect --strict.
      if echo "$out" | grep -q '(error)'; then
        LINT_FAILS=$((LINT_FAILS + 1))
        FAIL_PATHS+=("$rel")
        [ "$JSON" -eq 0 ] && printf "  ${R}LINT  ${Z}  %s\n%s\n" "$rel" "$(echo "$out" | sed 's/^/      /')"
      else
        LINT_WARNS=$((LINT_WARNS + 1))
        WARN_PATHS+=("$rel")
        if [ "$JSON" -eq 0 ]; then
          printf "  ${Y}WARN  ${Z}  %s\n" "$rel"
          echo "$out" | head -20 | sed 's/^/      /'
        fi
      fi
    else
      [ "$JSON" -eq 0 ] && printf "  ${G}OK    ${Z}  %s\n" "$rel"
    fi
  else
    [ "$JSON" -eq 0 ] && printf "  ${G}OK    ${Z}  %s ${D}(syntax only)${Z}\n" "$rel"
  fi
done

if [ "$JSON" -eq 1 ]; then
  printf '{\n  "total": %d,\n  "syntax_fails": %d,\n  "lint_fails": %d,\n  "lint_warns": %d,\n' \
    "$TOTAL" "$SYNTAX_FAILS" "$LINT_FAILS" "$LINT_WARNS"
  printf '  "shellcheck_used": %s,\n' "$([ "$HAVE_SHELLCHECK" -eq 1 ] && echo true || echo false)"
  printf '  "failed": ['
  for i in "${!FAIL_PATHS[@]}"; do
    sep=","; [ "$i" -eq $((${#FAIL_PATHS[@]} - 1)) ] && sep=""
    printf '"%s"%s' "${FAIL_PATHS[$i]}" "$sep"
  done
  printf '],\n  "warned": ['
  for i in "${!WARN_PATHS[@]}"; do
    sep=","; [ "$i" -eq $((${#WARN_PATHS[@]} - 1)) ] && sep=""
    printf '"%s"%s' "${WARN_PATHS[$i]}" "$sep"
  done
  printf ']\n}\n'
else
  echo ""
  printf "  ${B}Summary${Z}: %d files — ${G}%d ok${Z}" "$TOTAL" $((TOTAL - SYNTAX_FAILS - LINT_FAILS - LINT_WARNS))
  [ "$LINT_WARNS"   -gt 0 ] && printf ", ${Y}%d warn${Z}" "$LINT_WARNS"
  [ "$LINT_FAILS"   -gt 0 ] && printf ", ${R}%d lint-fail${Z}" "$LINT_FAILS"
  [ "$SYNTAX_FAILS" -gt 0 ] && printf ", ${R}%d syntax-fail${Z}" "$SYNTAX_FAILS"
  echo ""
  echo ""
fi

if [ "$SYNTAX_FAILS" -gt 0 ] || [ "$LINT_FAILS" -gt 0 ]; then
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$LINT_WARNS" -gt 0 ]; then
  exit 1
fi
exit 0
