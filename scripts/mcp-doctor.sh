#!/bin/bash
set -euo pipefail

# mcp-doctor.sh — Diagnose MCP server configurations across the supported CLIs.
# Inspects each CLI's config file (Claude / Codex / Gemini / Copilot), validates
# JSON/TOML where possible, and reports whether a Notion MCP server is wired up.
#
# Usage:
#   bash scripts/mcp-doctor.sh                # diagnose every CLI we can find
#   bash scripts/mcp-doctor.sh --server notion  # focus on a specific server name
#   bash scripts/mcp-doctor.sh --cli claude   # only check one CLI
#   bash scripts/mcp-doctor.sh --json         # machine-readable JSON output
#   bash scripts/mcp-doctor.sh --quiet        # exit code only, no human output

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

FOCUS_SERVER="notion"
FOCUS_CLI=""
JSON=0
QUIET=0

while [ $# -gt 0 ]; do
  case "$1" in
    --server) FOCUS_SERVER="$2"; shift 2 ;;
    --cli)    FOCUS_CLI="$2";    shift 2 ;;
    --json)   JSON=1;            shift   ;;
    --quiet)  QUIET=1;           shift   ;;
    -h|--help)
      sed -n '4,12p' "$0" | sed 's/^# *//'
      exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ -t 1 ] && [ "$JSON" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
  G='\033[32m'; R='\033[31m'; Y='\033[33m'; D='\033[90m'; B='\033[1m'; Z='\033[0m'
else
  G=''; R=''; Y=''; D=''; B=''; Z=''
fi

# Candidate config paths per CLI (first existing path wins).
claude_candidates=(
  "$HOME/.claude.json"
  "$HOME/.config/claude/claude.json"
  "$HOME/Library/Application Support/Claude/claude.json"
)
codex_candidates=(
  "$HOME/.codex/config.toml"
  "$HOME/.config/codex/config.toml"
)
gemini_candidates=(
  "$HOME/.gemini/settings.json"
  "$HOME/.config/gemini-cli/settings.json"
)
copilot_candidates=(
  "$HOME/.copilot/config.json"
  "$HOME/.config/github-copilot/cli-config.json"
)

first_existing() {
  for p in "$@"; do
    [ -f "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  return 1
}

# Result accumulators (parallel arrays keyed by index).
RES_CLI=(); RES_CONFIG=(); RES_VALID=(); RES_HAS_FOCUS=(); RES_SERVERS=(); RES_NOTES=()

add_result() {
  RES_CLI+=("$1"); RES_CONFIG+=("$2"); RES_VALID+=("$3"); RES_HAS_FOCUS+=("$4")
  RES_SERVERS+=("$5"); RES_NOTES+=("$6")
}

# ---- Claude / Gemini / Copilot (JSON-based mcpServers) ----------------------
inspect_json_mcp() {
  local cli="$1" config="$2"
  if [ ! -f "$config" ]; then
    add_result "$cli" "(none)" "missing" "no" "" "config file not found"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    add_result "$cli" "$config" "unknown" "unknown" "" "python3 missing — cannot parse JSON"
    return
  fi
  local probe
  probe="$(python3 - "$config" "$FOCUS_SERVER" <<'PY'
import json, sys, pathlib
p, focus = pathlib.Path(sys.argv[1]), sys.argv[2]
try:
    data = json.loads(p.read_text() or "{}")
except Exception as e:
    print("INVALID|" + str(e).splitlines()[0])
    sys.exit(0)

# mcpServers can live at the top level or nested under "claudeCode" / project entries.
def collect(d, out):
    if isinstance(d, dict):
        if "mcpServers" in d and isinstance(d["mcpServers"], dict):
            for name in d["mcpServers"].keys():
                out.add(name)
        for v in d.values():
            collect(v, out)
    elif isinstance(d, list):
        for v in d:
            collect(v, out)

names = set()
collect(data, names)
has_focus = "yes" if focus in names else "no"
print("OK|" + has_focus + "|" + ",".join(sorted(names)))
PY
)"
  local kind="${probe%%|*}" rest="${probe#*|}"
  case "$kind" in
    INVALID)
      add_result "$cli" "$config" "invalid" "no" "" "JSON parse error: $rest" ;;
    OK)
      local has="${rest%%|*}" servers="${rest#*|}"
      [ "$servers" = "$rest" ] && servers=""
      local note=""
      [ -z "$servers" ] && note="no mcpServers block found"
      add_result "$cli" "$config" "valid" "$has" "$servers" "$note" ;;
    *)
      add_result "$cli" "$config" "unknown" "no" "" "parser produced no output" ;;
  esac
}

# ---- Codex (TOML-based [mcp_servers]) ---------------------------------------
inspect_codex_mcp() {
  local config="$1"
  if [ ! -f "$config" ]; then
    add_result "codex" "(none)" "missing" "no" "" "config file not found"
    return
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    add_result "codex" "$config" "unknown" "unknown" "" "python3 missing — cannot parse TOML"
    return
  fi
  local probe
  probe="$(python3 - "$config" "$FOCUS_SERVER" <<'PY'
import sys, pathlib
p, focus = pathlib.Path(sys.argv[1]), sys.argv[2]
text = p.read_text() if p.exists() else ""
try:
    try:
        import tomllib  # 3.11+
    except ImportError:
        import tomli as tomllib  # type: ignore
    data = tomllib.loads(text)
except Exception as e:
    # Fall back to regex scan for [mcp_servers.<name>] sections so we still report something.
    import re
    names = sorted(set(re.findall(r'^\[mcp_servers\.([A-Za-z0-9_\-]+)\]', text, re.M)))
    has = "yes" if focus in names else "no"
    print("REGEX|" + has + "|" + ",".join(names) + "|" + str(e).splitlines()[0])
    sys.exit(0)

servers = data.get("mcp_servers") or data.get("mcpServers") or {}
if not isinstance(servers, dict):
    servers = {}
names = sorted(servers.keys())
has = "yes" if focus in names else "no"
print("OK|" + has + "|" + ",".join(names))
PY
)"
  local kind="${probe%%|*}" rest="${probe#*|}"
  case "$kind" in
    OK)
      local has="${rest%%|*}" servers="${rest#*|}"
      [ "$servers" = "$rest" ] && servers=""
      local note=""; [ -z "$servers" ] && note="no [mcp_servers] section found"
      add_result "codex" "$config" "valid" "$has" "$servers" "$note" ;;
    REGEX)
      local r1="${rest%%|*}"; local r2="${rest#*|}"
      local has="$r1" servers="${r2%%|*}" err="${r2#*|}"
      add_result "codex" "$config" "partial" "$has" "$servers" "tomllib failed ($err); used regex fallback" ;;
    *)
      add_result "codex" "$config" "unknown" "no" "" "parser produced no output" ;;
  esac
}

run_one() {
  local cli="$1" cfg
  case "$cli" in
    claude)
      cfg="$(first_existing "${claude_candidates[@]}" || true)"
      inspect_json_mcp "claude" "${cfg:-${claude_candidates[0]}}"
      ;;
    codex)
      cfg="$(first_existing "${codex_candidates[@]}" || true)"
      inspect_codex_mcp "${cfg:-${codex_candidates[0]}}"
      ;;
    gemini)
      cfg="$(first_existing "${gemini_candidates[@]}" || true)"
      inspect_json_mcp "gemini" "${cfg:-${gemini_candidates[0]}}"
      ;;
    copilot)
      cfg="$(first_existing "${copilot_candidates[@]}" || true)"
      inspect_json_mcp "copilot" "${cfg:-${copilot_candidates[0]}}"
      ;;
    *) echo "Unknown CLI: $cli" >&2; exit 2 ;;
  esac
}

if [ -n "$FOCUS_CLI" ]; then
  run_one "$FOCUS_CLI"
else
  run_one claude
  run_one codex
  run_one gemini
  run_one copilot
fi

OK_COUNT=0
HAS_FOCUS_ANY=0
TOTAL=${#RES_CLI[@]}
for i in $(seq 0 $((TOTAL - 1))); do
  [ "${RES_VALID[$i]}" = "valid" ] && OK_COUNT=$((OK_COUNT + 1))
  [ "${RES_HAS_FOCUS[$i]}" = "yes" ] && HAS_FOCUS_ANY=1
done

if [ "$JSON" -eq 1 ]; then
  printf '{\n'
  printf '  "focus_server": "%s",\n' "$FOCUS_SERVER"
  printf '  "has_focus_any": %s,\n' "$([ "$HAS_FOCUS_ANY" -eq 1 ] && echo true || echo false)"
  printf '  "results": [\n'
  for i in $(seq 0 $((TOTAL - 1))); do
    sep=","; [ "$i" -eq $((TOTAL - 1)) ] && sep=""
    printf '    {"cli":"%s","config":"%s","status":"%s","has_focus":"%s","servers":"%s","note":"%s"}%s\n' \
      "${RES_CLI[$i]}" "${RES_CONFIG[$i]}" "${RES_VALID[$i]}" "${RES_HAS_FOCUS[$i]}" "${RES_SERVERS[$i]}" "${RES_NOTES[$i]}" "$sep"
  done
  printf '  ]\n}\n'
  exit 0
fi

if [ "$QUIET" -eq 0 ]; then
  echo ""
  printf "  ${B}MCP doctor${Z}  (focus server: ${B}%s${Z})\n" "$FOCUS_SERVER"
  echo "  ============================================="
  printf "  %-9s %-9s %-8s  %s\n" "cli" "status" "$FOCUS_SERVER?" "config / servers"
  printf "  %-9s %-9s %-8s  %s\n" "---" "------" "-------" "----------------"
  for i in $(seq 0 $((TOTAL - 1))); do
    color="$D"
    case "${RES_VALID[$i]}" in
      valid)   color="$G" ;;
      missing) color="$D" ;;
      invalid) color="$R" ;;
      partial) color="$Y" ;;
    esac
    has_color="$D"
    [ "${RES_HAS_FOCUS[$i]}" = "yes" ] && has_color="$G"
    [ "${RES_HAS_FOCUS[$i]}" = "no" ]  && [ "${RES_VALID[$i]}" = "valid" ] && has_color="$Y"
    printf "  %-9s ${color}%-9s${Z} ${has_color}%-8s${Z}  ${D}%s${Z}\n" \
      "${RES_CLI[$i]}" "${RES_VALID[$i]}" "${RES_HAS_FOCUS[$i]}" "${RES_CONFIG[$i]}"
    if [ -n "${RES_SERVERS[$i]}" ]; then
      printf "                                  servers: %s\n" "${RES_SERVERS[$i]}"
    fi
    if [ -n "${RES_NOTES[$i]}" ]; then
      printf "                                  note: %s\n" "${RES_NOTES[$i]}"
    fi
  done
  echo ""
  if [ "$HAS_FOCUS_ANY" -eq 1 ]; then
    printf "  ${G}OK${Z}: at least one CLI has '%s' configured.\n\n" "$FOCUS_SERVER"
  else
    printf "  ${Y}WARN${Z}: '%s' not configured in any inspected CLI.\n" "$FOCUS_SERVER"
    printf "        Add an MCP server entry — see README.md > Notion Setup.\n\n"
  fi
fi

[ "$HAS_FOCUS_ANY" -eq 1 ] || exit 1
