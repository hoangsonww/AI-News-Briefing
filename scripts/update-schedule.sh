#!/bin/bash
set -euo pipefail

# update-schedule.sh — Change the daily briefing schedule on macOS.
#
# Edits the INSTALLED launchd plist in place with PlistBuddy (so webhook secrets
# and other keys are preserved) and reloads the agent.
#
# Usage:
#   ./scripts/update-schedule.sh HOUR [MINUTE]        # set host-local anchor time
#   ./scripts/update-schedule.sh --tz ZONE            # set the briefing timezone
#   ./scripts/update-schedule.sh --tz ZONE HOUR [MIN] # both
#
# Examples:
#   ./scripts/update-schedule.sh 7 30                 # anchor at 07:30 host-local
#   ./scripts/update-schedule.sh --tz America/New_York
#   ./scripts/update-schedule.sh --tz Europe/London 9
#
# The briefing fires at 08:00 in AI_BRIEFING_TZ (default America/Los_Angeles)
# regardless of the host clock; the 30-min poll + Pacific guard in briefing.sh
# do the real pinning. HOUR/MINUTE only move the punctual host-local anchor
# (the first StartCalendarInterval entry). --tz changes the zone the 08:00 gate
# and the briefing's "today" are evaluated in.

LABEL="com.ainews.briefing"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
PB="/usr/libexec/PlistBuddy"

if [ "$(uname -s)" != "Darwin" ]; then
    echo "This script is for macOS only." >&2
    echo "On Windows, set the zone with: setx AI_BRIEFING_TZ \"Eastern Standard Time\"" >&2
    echo "and the time with: .\\install-task.ps1 -Hour HH -Minute MM" >&2
    exit 1
fi
[ -f "$PLIST" ] || { echo "ERROR: $PLIST not found. Run 'make install' first." >&2; exit 1; }
[ -x "$PB" ]    || { echo "ERROR: PlistBuddy not found at $PB." >&2; exit 1; }

TZ_ARG=""
HOUR=""
MINUTE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tz)
            [[ $# -lt 2 ]] && { echo "ERROR: --tz requires a zone (e.g. America/New_York)" >&2; exit 1; }
            TZ_ARG="$2"; shift 2 ;;
        -*)
            echo "Unknown option: $1" >&2; exit 1 ;;
        *)
            if   [ -z "$HOUR" ];   then HOUR="$1"
            elif [ -z "$MINUTE" ]; then MINUTE="$1"
            else echo "Unexpected argument: $1" >&2; exit 1
            fi
            shift ;;
    esac
done

if [ -z "$TZ_ARG" ] && [ -z "$HOUR" ]; then
    echo "Usage: update-schedule.sh [HOUR [MINUTE]] [--tz ZONE]" >&2
    echo "  update-schedule.sh 7 30                 # host-local anchor 07:30" >&2
    echo "  update-schedule.sh --tz America/New_York" >&2
    exit 1
fi

echo ""

# -- Timezone --------------------------------------------------
if [ -n "$TZ_ARG" ]; then
    # Sanity-check the zone resolves on this host.
    if ! TZ="$TZ_ARG" date >/dev/null 2>&1; then
        echo "  WARNING: '$TZ_ARG' may not be a valid IANA zone on this host." >&2
    fi
    "$PB" -c "Set :EnvironmentVariables:AI_BRIEFING_TZ $TZ_ARG" "$PLIST" 2>/dev/null \
        || "$PB" -c "Add :EnvironmentVariables:AI_BRIEFING_TZ string $TZ_ARG" "$PLIST"
    echo "  Timezone -> $TZ_ARG"
fi

# -- Host-local anchor time ------------------------------------
if [ -n "$HOUR" ]; then
    if ! [[ "$HOUR" =~ ^[0-9]+$ ]] || [ "$((10#$HOUR))" -lt 0 ] || [ "$((10#$HOUR))" -gt 23 ]; then
        echo "Invalid hour: $HOUR (must be 0-23)" >&2; exit 1
    fi
    MINUTE="${MINUTE:-0}"
    if ! [[ "$MINUTE" =~ ^[0-9]+$ ]] || [ "$((10#$MINUTE))" -lt 0 ] || [ "$((10#$MINUTE))" -gt 59 ]; then
        echo "Invalid minute: $MINUTE (must be 0-59)" >&2; exit 1
    fi
    # First StartCalendarInterval entry is the punctual anchor. Support both the
    # array form (:0:) and a legacy single-dict form.
    "$PB" -c "Set :StartCalendarInterval:0:Hour $((10#$HOUR))" "$PLIST" 2>/dev/null \
        || "$PB" -c "Set :StartCalendarInterval:Hour $((10#$HOUR))" "$PLIST"
    "$PB" -c "Set :StartCalendarInterval:0:Minute $((10#$MINUTE))" "$PLIST" 2>/dev/null \
        || "$PB" -c "Set :StartCalendarInterval:Minute $((10#$MINUTE))" "$PLIST"
    printf "  Host-local anchor -> %02d:%02d\n" "$((10#$HOUR))" "$((10#$MINUTE))"
fi

# -- Validate & reload -----------------------------------------
plutil -lint "$PLIST" >/dev/null
launchctl unload "$PLIST" 2>/dev/null || true
launchctl load "$PLIST"

echo "  Plist updated and agent reloaded."
echo ""
echo "  Briefing fires at 08:00 in its timezone (default America/Los_Angeles)."
echo "  Verify: launchctl list | grep ainews"
echo ""
