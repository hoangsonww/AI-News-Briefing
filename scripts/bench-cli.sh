#!/bin/bash
set -euo pipefail

# bench-cli.sh — Tiny benchmark of each installed AI CLI.
# Sends a one-line prompt to each engine in turn, measuring wall-clock time
# and capturing whether it responded with non-empty output before a timeout.
# Useful for picking the snappiest engine on the current network.
#
# Usage:
#   bash scripts/bench-cli.sh                 # run all installed engines
#   bash scripts/bench-cli.sh --timeout 45    # per-engine timeout (default 30s)
#   bash scripts/bench-cli.sh --only claude,gemini
#   bash scripts/bench-cli.sh --prompt "Reply with the word OK only."
#   bash scripts/bench-cli.sh --json

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

TIMEOUT=30
ONLY=""
JSON=0
PROMPT='Reply with exactly the two characters: OK. No quotes, no extra words.'

while [ $# -gt 0 ]; do
  case "$1" in
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --only)    ONLY="$2";    shift 2 ;;
    --prompt)  PROMPT="$2";  shift 2 ;;
    --json)    JSON=1;       shift   ;;
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

resolve_binary() {
  local cli="$1"
  case "$cli" in
    claude)
      for p in "${HOME}/.local/bin/claude" "${HOME}/.local/bin/claude.exe"; do
        [ -x "$p" ] && { echo "$p"; return 0; }
      done
      command -v claude 2>/dev/null && return 0
      return 1 ;;
    codex|gemini|copilot)
      command -v "$cli" 2>/dev/null && return 0
      return 1 ;;
    *) return 1 ;;
  esac
}

# Pick a `timeout` impl: GNU coreutils on Linux, `gtimeout` on macOS if installed,
# or fall back to a backgrounded subshell + kill.
TIMEOUT_CMD=""
if command -v timeout >/dev/null 2>&1; then TIMEOUT_CMD="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_CMD="gtimeout"
fi

run_with_timeout() {
  # run_with_timeout SECS CMD [ARGS...] — writes stdout to caller, returns exit code.
  local secs="$1"; shift
  if [ -n "$TIMEOUT_CMD" ]; then
    "$TIMEOUT_CMD" "$secs" "$@"
    return $?
  fi
  # Manual fallback: race the process against `sleep`.
  ( "$@" ) &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
  local killer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return "$rc"
}

millis_now() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    echo "$(($(date +%s) * 1000))"
  fi
}

run_engine() {
  local cli="$1" bin="$2"
  local out_file rc start end ms
  out_file="$(mktemp -t bench-cli.XXXXXX)"
  start="$(millis_now)"
  case "$cli" in
    claude)  run_with_timeout "$TIMEOUT" "$bin" -p --dangerously-skip-permissions "$PROMPT" >"$out_file" 2>/dev/null || rc=$? ;;
    codex)   run_with_timeout "$TIMEOUT" "$bin" exec --full-auto "$PROMPT" >"$out_file" 2>/dev/null || rc=$? ;;
    gemini)  run_with_timeout "$TIMEOUT" "$bin" -p "$PROMPT" >"$out_file" 2>/dev/null || rc=$? ;;
    copilot) run_with_timeout "$TIMEOUT" "$bin" --prompt "$PROMPT" --allow-all-tools --allow-all-paths --allow-all-urls >"$out_file" 2>/dev/null || rc=$? ;;
  esac
  end="$(millis_now)"
  rc="${rc:-0}"
  ms=$((end - start))

  local bytes
  bytes=$(wc -c <"$out_file" 2>/dev/null | tr -d ' ' || echo 0)
  local preview
  preview="$(head -c 80 "$out_file" 2>/dev/null | tr '\n\t' '  ')"
  rm -f "$out_file"

  echo "$cli|$rc|$ms|$bytes|$preview"
}

want() {
  local cli="$1"
  [ -z "$ONLY" ] && return 0
  case ",$ONLY," in *",$cli,"*) return 0 ;; esac
  return 1
}

declare -a ROWS

for cli in claude codex gemini copilot; do
  want "$cli" || continue
  if bin=$(resolve_binary "$cli" 2>/dev/null); then
    ROWS+=("$(run_engine "$cli" "$bin")")
  else
    ROWS+=("$cli|missing|0|0|not installed")
  fi
done

if [ "$JSON" -eq 1 ]; then
  printf '{\n  "timeout": %d,\n  "prompt": %s,\n  "results": [\n' "$TIMEOUT" "$(printf '%s' "$PROMPT" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')"
  for i in "${!ROWS[@]}"; do
    IFS='|' read -r cli rc ms bytes preview <<<"${ROWS[$i]}"
    sep=","; [ "$i" -eq $((${#ROWS[@]} - 1)) ] && sep=""
    pj="$(printf '%s' "$preview" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' 2>/dev/null || echo '""')"
    printf '    {"cli":"%s","exit_code":"%s","ms":%s,"bytes":%s,"preview":%s}%s\n' \
      "$cli" "$rc" "$ms" "$bytes" "$pj" "$sep"
  done
  printf '  ]\n}\n'
  exit 0
fi

echo ""
printf "  ${B}bench-cli${Z}  (timeout %ss)\n" "$TIMEOUT"
echo "  ============================================="
printf "  %-9s %-10s %-9s %-9s  %s\n" "engine" "status" "wall (ms)" "bytes" "preview"
printf "  %-9s %-10s %-9s %-9s  %s\n" "------" "------" "---------" "-----" "-------"

for row in "${ROWS[@]}"; do
  IFS='|' read -r cli rc ms bytes preview <<<"$row"
  if [ "$rc" = "missing" ]; then
    printf "  %-9s ${D}%-10s${Z} %-9s %-9s  ${D}%s${Z}\n" "$cli" "missing" "-" "-" "$preview"
    continue
  fi
  if [ "$rc" = "0" ] && [ "$bytes" -gt 0 ]; then
    color="$G"; label="ok"
  elif [ "$rc" = "124" ] || [ "$rc" = "143" ]; then
    color="$Y"; label="timeout"
  else
    color="$R"; label="fail($rc)"
  fi
  printf "  %-9s ${color}%-10s${Z} %-9s %-9s  ${D}%s${Z}\n" "$cli" "$label" "$ms" "$bytes" "$preview"
done

echo ""
printf "  ${D}Note: a clean 'OK' preview means the engine responded; long previews may include MOTD/warnings.${Z}\n"
echo ""
