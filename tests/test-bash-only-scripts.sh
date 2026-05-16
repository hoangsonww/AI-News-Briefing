#!/bin/bash
# Tests for the bash-only utility scripts (no PowerShell mirror).
# Covers: stats, shell-lint, mcp-doctor, render-card, brief-diff, prune-artifacts,
#         open-brief, bench-cli, weekly-digest, topic-stats, git-hooks-install,
#         quiet-hours.
# All checks are non-blocking: no webhooks, no Claude calls, no network.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

PASS=0
FAIL=0

if [[ -t 1 ]]; then
  B='\033[1m'; D='\033[2m'; R='\033[0m'
  GRN='\033[32m'; RED='\033[31m'; CYN='\033[36m'; YLW='\033[33m'; MAG='\033[35m'
else
  B=''; D=''; R=''; GRN=''; RED=''; CYN=''; YLW=''; MAG=''
fi

pass() { PASS=$((PASS + 1)); echo -e "  ${GRN}PASS${R}  $1"; }
fail() { FAIL=$((FAIL + 1)); echo -e "  ${RED}FAIL${R}  $1"; }
section() { echo ""; echo -e "  ${CYN}${B}$1${R}"; }
assert_contains() {
  if echo "$1" | grep -qF -- "$2"; then pass "$3"; else fail "$3 ${D}(missing '$2')${R}"; fi
}
assert_exit() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then pass "$label"; else fail "$label ${D}(exit $actual, expected $expected)${R}"; fi
}
assert_valid_json() {
  if echo "$1" | python3 -m json.tool >/dev/null 2>&1; then pass "$2"; else fail "$2 ${D}(invalid JSON)${R}"; fi
}

BASH_ONLY=(
  stats shell-lint mcp-doctor render-card brief-diff prune-artifacts
  open-brief bench-cli weekly-digest topic-stats git-hooks-install quiet-hours
)

echo ""
echo -e "  ${MAG}${B}================================================${R}"
echo -e "  ${MAG}${B}  bash-only utility script tests${R}"
echo -e "  ${MAG}${B}================================================${R}"

# -- Existence + executability ---------------------------------------------
section "Script existence + executability"
for name in "${BASH_ONLY[@]}"; do
  f="$SCRIPT_DIR/scripts/$name.sh"
  if [ -f "$f" ]; then
    pass "scripts/$name.sh exists"
    if [ -x "$f" ]; then pass "scripts/$name.sh is executable"
    else fail "scripts/$name.sh is executable"; fi
  else
    fail "scripts/$name.sh exists"
  fi
done

# -- No PS1 mirror (these are intentionally bash-only) ---------------------
section "No PowerShell mirror"
for name in "${BASH_ONLY[@]}"; do
  if [ -f "$SCRIPT_DIR/scripts/$name.ps1" ]; then
    fail "scripts/$name.ps1 should NOT exist (bash-only)"
  else
    pass "scripts/$name.ps1 absent (bash-only)"
  fi
done

# -- Bash syntax + strict-mode header --------------------------------------
section "Bash syntax + strict mode"
for name in "${BASH_ONLY[@]}"; do
  f="$SCRIPT_DIR/scripts/$name.sh"
  if bash -n "$f" 2>/dev/null; then pass "scripts/$name.sh valid bash syntax"
  else fail "scripts/$name.sh valid bash syntax"; fi
  HEADER="$(head -5 "$f")"
  assert_contains "$HEADER" "set -euo pipefail" "scripts/$name.sh uses set -euo pipefail"
done

# -- --help exits 0 with Usage ---------------------------------------------
section "--help flag"
for name in "${BASH_ONLY[@]}"; do
  OUT="$(bash "$SCRIPT_DIR/scripts/$name.sh" --help 2>&1)"; RC=$?
  assert_exit "$RC" "0" "scripts/$name.sh --help exits 0"
  assert_contains "$OUT" "Usage:" "scripts/$name.sh --help shows Usage"
done

# -- Unknown flag returns non-zero -----------------------------------------
section "Unknown flag handling"
# Most accept --unknown-flag and exit 2. quiet-hours / git-hooks-install also do.
for name in stats shell-lint mcp-doctor render-card brief-diff prune-artifacts \
            open-brief bench-cli weekly-digest topic-stats git-hooks-install quiet-hours; do
  OUT="$(bash "$SCRIPT_DIR/scripts/$name.sh" --definitely-not-a-flag 2>&1)"; RC=$?
  if [ "$RC" -ne 0 ]; then pass "scripts/$name.sh rejects unknown flag"
  else fail "scripts/$name.sh rejects unknown flag (got exit 0)"; fi
done

# -- stats.sh --json -------------------------------------------------------
section "stats.sh"
OUT="$(bash "$SCRIPT_DIR/scripts/stats.sh" 2>&1)"; RC=$?
assert_exit "$RC" "0" "stats.sh exits 0"
assert_contains "$OUT" "Source"     "stats.sh prints Source section"
assert_contains "$OUT" "scripts/"   "stats.sh prints scripts/ section"
OUT_JSON="$(bash "$SCRIPT_DIR/scripts/stats.sh" --json 2>&1)"; RC=$?
assert_exit "$RC" "0" "stats.sh --json exits 0"
assert_valid_json "$OUT_JSON" "stats.sh --json emits valid JSON"

# -- shell-lint.sh against own repo ----------------------------------------
section "shell-lint.sh"
OUT="$(bash "$SCRIPT_DIR/scripts/shell-lint.sh" --path "$SCRIPT_DIR/scripts" 2>&1)"; RC=$?
assert_exit "$RC" "0" "shell-lint.sh exits 0 over scripts/"
assert_contains "$OUT" "Summary"   "shell-lint.sh prints summary"
OUT_JSON="$(bash "$SCRIPT_DIR/scripts/shell-lint.sh" --path "$SCRIPT_DIR/scripts" --json 2>&1)"; RC=$?
assert_exit "$RC" "0" "shell-lint.sh --json exits 0"
assert_valid_json "$OUT_JSON" "shell-lint.sh --json emits valid JSON"
if echo "$OUT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['syntax_fails']==0 else 1)" 2>/dev/null; then
  pass "shell-lint.sh reports 0 syntax failures in scripts/"
else
  fail "shell-lint.sh reports 0 syntax failures in scripts/"
fi

# -- mcp-doctor.sh ---------------------------------------------------------
section "mcp-doctor.sh"
OUT_JSON="$(bash "$SCRIPT_DIR/scripts/mcp-doctor.sh" --json 2>&1 || true)"
assert_valid_json "$OUT_JSON" "mcp-doctor.sh --json emits valid JSON"
if echo "$OUT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if len(d['results'])==4 else 1)" 2>/dev/null; then
  pass "mcp-doctor.sh reports on all 4 CLIs"
else
  fail "mcp-doctor.sh reports on all 4 CLIs"
fi

# -- render-card.sh against an example card --------------------------------
section "render-card.sh"
SAMPLE="$(ls "$SCRIPT_DIR"/example-cards/*-card.json 2>/dev/null | head -1)"
if [ -n "$SAMPLE" ]; then
  SAMPLE_DATE="$(basename "$SAMPLE" -card.json)"
  OUT="$(bash "$SCRIPT_DIR/scripts/render-card.sh" --example "$SAMPLE_DATE" --no-color 2>&1)"; RC=$?
  assert_exit "$RC" "0" "render-card.sh exits 0 on example card"
  assert_contains "$OUT" "AI Daily Briefing" "render-card.sh shows header"
  assert_contains "$OUT" "→"                 "render-card.sh shows action arrow"
  OUT="$(bash "$SCRIPT_DIR/scripts/render-card.sh" --file /tmp/does-not-exist.json 2>&1)"; RC=$?
  assert_exit "$RC" "1" "render-card.sh exits 1 on missing file"
else
  fail "render-card.sh: no example card to test against"
fi

# -- brief-diff.sh between two example cards -------------------------------
section "brief-diff.sh"
DIFF_A="$(ls "$SCRIPT_DIR"/example-cards/*-card.json 2>/dev/null | head -1)"
DIFF_B="$(ls "$SCRIPT_DIR"/example-cards/*-card.json 2>/dev/null | sed -n 2p)"
if [ -n "$DIFF_A" ] && [ -n "$DIFF_B" ]; then
  AD="$(basename "$DIFF_A" -card.json)"; BD="$(basename "$DIFF_B" -card.json)"
  OUT="$(bash "$SCRIPT_DIR/scripts/brief-diff.sh" --example --from "$AD" --to "$BD" --plain 2>&1)"; RC=$?
  # diff returns 1 when files differ, 0 when same. Either is fine.
  if [ "$RC" -eq 0 ] || [ "$RC" -eq 1 ]; then pass "brief-diff.sh runs cleanly on two example cards"
  else fail "brief-diff.sh exits 0 or 1 (got $RC)"; fi
else
  fail "brief-diff.sh: need at least 2 example cards"
fi

# -- prune-artifacts.sh dry-run --------------------------------------------
section "prune-artifacts.sh"
OUT="$(bash "$SCRIPT_DIR/scripts/prune-artifacts.sh" 2>&1)"; RC=$?
assert_exit "$RC" "0" "prune-artifacts.sh dry-run exits 0"
assert_contains "$OUT" "dry-run" "prune-artifacts.sh advertises dry-run mode"
OUT_JSON="$(bash "$SCRIPT_DIR/scripts/prune-artifacts.sh" --json 2>&1)"; RC=$?
assert_valid_json "$OUT_JSON" "prune-artifacts.sh --json emits valid JSON"
if echo "$OUT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['dry_run'] is True else 1)" 2>/dev/null; then
  pass "prune-artifacts.sh --json reports dry_run:true by default"
else
  fail "prune-artifacts.sh --json reports dry_run:true by default"
fi

# Synthetic orphan -> --apply removes it
TMP_LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$TMP_LOG_DIR"
ORPHAN_FILE="$TMP_LOG_DIR/1999-01-01-card.json"
echo '{"orphan": true}' > "$ORPHAN_FILE"
OUT="$(bash "$SCRIPT_DIR/scripts/prune-artifacts.sh" 2>&1)"
assert_contains "$OUT" "1999-01-01" "prune-artifacts.sh detects synthetic orphan"
OUT="$(bash "$SCRIPT_DIR/scripts/prune-artifacts.sh" --apply 2>&1)"
if [ ! -f "$ORPHAN_FILE" ]; then pass "prune-artifacts.sh --apply deletes orphan"
else fail "prune-artifacts.sh --apply deletes orphan"; rm -f "$ORPHAN_FILE"; fi

# -- open-brief.sh dry-run path resolution ---------------------------------
section "open-brief.sh"
OUT="$(bash "$SCRIPT_DIR/scripts/open-brief.sh" --dry-run --what dir 2>&1)"; RC=$?
assert_exit "$RC" "0" "open-brief.sh --dry-run --what dir exits 0"
assert_contains "$OUT" "logs" "open-brief.sh --what dir resolves to logs path"
OUT="$(bash "$SCRIPT_DIR/scripts/open-brief.sh" --what bogus 2>&1)"; RC=$?
assert_exit "$RC" "2" "open-brief.sh rejects bogus --what value"

# -- bench-cli.sh sanity ---------------------------------------------------
section "bench-cli.sh"
OUT_JSON="$(bash "$SCRIPT_DIR/scripts/bench-cli.sh" --only nonexistent-cli --timeout 1 --json 2>&1)"
# With --only matching no real engine, results array should be empty + valid JSON.
assert_valid_json "$OUT_JSON" "bench-cli.sh --json emits valid JSON"

# -- weekly-digest.sh on the live repo -------------------------------------
section "weekly-digest.sh"
OUT="$(bash "$SCRIPT_DIR/scripts/weekly-digest.sh" --days 365 2>&1)"; RC=$?
assert_exit "$RC" "0" "weekly-digest.sh exits 0"
assert_contains "$OUT" "weekly digest" "weekly-digest.sh prints header"
OUT_JSON="$(bash "$SCRIPT_DIR/scripts/weekly-digest.sh" --days 365 --json 2>&1)"; RC=$?
assert_exit "$RC" "0" "weekly-digest.sh --json exits 0"
assert_valid_json "$OUT_JSON" "weekly-digest.sh --json emits valid JSON"

# -- topic-stats.sh on a synthetic file ------------------------------------
section "topic-stats.sh"
TMP_OBS="$TMP_LOG_DIR/1999-12-31-obsidian.md"
{
  echo "## Today"
  echo "- [[Test Topic]] and [[Another]]"
  echo "- [[Test Topic|alias]] again"
} > "$TMP_OBS"
OUT_JSON="$(bash "$SCRIPT_DIR/scripts/topic-stats.sh" --json 2>&1)"
assert_valid_json "$OUT_JSON" "topic-stats.sh --json emits valid JSON"
if echo "$OUT_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); names=[t['topic'] for t in d['topics']]; sys.exit(0 if 'Test Topic' in names else 1)" 2>/dev/null; then
  pass "topic-stats.sh detects synthetic [[wikilink]]"
else
  fail "topic-stats.sh detects synthetic [[wikilink]]"
fi
rm -f "$TMP_OBS"

# -- git-hooks-install.sh status -------------------------------------------
section "git-hooks-install.sh"
OUT="$(bash "$SCRIPT_DIR/scripts/git-hooks-install.sh" --status 2>&1)"; RC=$?
assert_exit "$RC" "0" "git-hooks-install.sh --status exits 0"
if echo "$OUT" | grep -qE "(installed|not installed)"; then
  pass "git-hooks-install.sh --status reports install state"
else
  fail "git-hooks-install.sh --status reports install state"
fi

# Real install/uninstall round-trip (only if we're in a working tree).
if [ -d "$SCRIPT_DIR/.git" ]; then
  EXISTING_HOOK=""
  if [ -f "$SCRIPT_DIR/.git/hooks/pre-commit" ]; then
    EXISTING_HOOK="$(mktemp -t pre-commit-backup.XXXXXX)"
    cp "$SCRIPT_DIR/.git/hooks/pre-commit" "$EXISTING_HOOK"
    rm -f "$SCRIPT_DIR/.git/hooks/pre-commit"
  fi
  OUT="$(bash "$SCRIPT_DIR/scripts/git-hooks-install.sh" 2>&1)"; RC=$?
  assert_exit "$RC" "0" "git-hooks-install.sh installs cleanly"
  [ -f "$SCRIPT_DIR/.git/hooks/pre-commit" ] && pass "pre-commit hook file exists after install" || fail "pre-commit hook file exists after install"
  [ -x "$SCRIPT_DIR/.git/hooks/pre-commit" ] && pass "pre-commit hook is executable" || fail "pre-commit hook is executable"
  bash -n "$SCRIPT_DIR/.git/hooks/pre-commit" 2>/dev/null && pass "installed pre-commit hook has valid bash syntax" || fail "installed pre-commit hook has valid bash syntax"
  OUT="$(bash "$SCRIPT_DIR/scripts/git-hooks-install.sh" --uninstall 2>&1)"; RC=$?
  assert_exit "$RC" "0" "git-hooks-install.sh --uninstall exits 0"
  [ ! -f "$SCRIPT_DIR/.git/hooks/pre-commit" ] && pass "pre-commit hook removed after uninstall" || fail "pre-commit hook removed after uninstall"
  if [ -n "$EXISTING_HOOK" ]; then
    cp "$EXISTING_HOOK" "$SCRIPT_DIR/.git/hooks/pre-commit"
    chmod +x "$SCRIPT_DIR/.git/hooks/pre-commit"
    rm -f "$EXISTING_HOOK"
  fi
fi

# -- quiet-hours.sh status -------------------------------------------------
section "quiet-hours.sh"
OUT="$(bash "$SCRIPT_DIR/scripts/quiet-hours.sh" 2>&1)"; RC=$?
assert_exit "$RC" "0" "quiet-hours.sh exits 0"
OUT_JSON="$(bash "$SCRIPT_DIR/scripts/quiet-hours.sh" --json 2>&1)"; RC=$?
assert_exit "$RC" "0" "quiet-hours.sh --json exits 0"
assert_valid_json "$OUT_JSON" "quiet-hours.sh --json emits valid JSON"

# -- Makefile targets ------------------------------------------------------
section "Makefile targets"
for tgt in stats shell-lint mcp-doctor render-card brief-diff prune-artifacts \
           open-brief bench-cli weekly-digest topic-stats git-hooks-install quiet-hours; do
  if grep -qE "^${tgt}:" "$SCRIPT_DIR/Makefile"; then
    pass "Makefile has ${tgt} target"
  else
    fail "Makefile has ${tgt} target"
  fi
done

# -- README mentions every new script --------------------------------------
section "README coverage"
for tgt in stats shell-lint mcp-doctor render-card brief-diff prune-artifacts \
           open-brief bench-cli weekly-digest topic-stats git-hooks-install quiet-hours; do
  if grep -qE "(scripts/${tgt}\.sh|\`${tgt}\`)" "$SCRIPT_DIR/README.md"; then
    pass "README mentions ${tgt}"
  else
    fail "README mentions ${tgt}"
  fi
done

# -- Summary ---------------------------------------------------------------
echo ""
echo -e "  ${B}================================================${R}"
if [[ "$FAIL" -eq 0 ]]; then
  echo -e "  ${GRN}${B}ALL PASSED  $PASS tests${R}"
else
  echo -e "  ${RED}${B}$FAIL of $((PASS + FAIL)) failed${R}"
fi
echo -e "  ${B}================================================${R}"

exit "$FAIL"
