#!/bin/zsh
# Mascot animation power benchmark (goal: idle mascot CPU ≤2%).
#
# Measures CodeIsland's CPU with a single working session on screen in two
# notch states, 60s each:
#   collapsed — mouse parked far away; only the compact notch bar animates
#   expanded  — mouse parked over the notch; full panel with cards animates
#
# Usage: scripts/measure-mascot-power.sh [path-to-CodeIsland.app] [scenario]
#   scenario: working (default) | idle — which mock session the preview injects.
# Requires /tmp/mousemove (see spec animation-performance.md for the source).

set -u
APP=${1:-.build/release/CodeIsland.app}
SCENARIO=${2:-working}
BIN="$APP/Contents/MacOS/CodeIsland"
DURATION=60

read SW SH <<< "$(/tmp/mousemove screen)"
CX=$((SW / 2)); NOTCH_Y=12           # notch bar: top-centre
AWAY_X=40;  AWAY_Y=$((SH - 40))      # bottom-left corner

# Don't fight the real running instance.
killall CodeIsland 2>/dev/null; sleep 1

"$BIN" --preview "$SCENARIO" >/dev/null 2>&1 &
APP_PID=$!
sleep 6

measure() {  # $1 = label
  local total=0 n=0 peak=0 v
  for _ in $(seq 1 $((DURATION / 2))); do
    v=$(ps -p $APP_PID -o %cpu= | tr -d ' ')
    [ -z "$v" ] && break
    total=$((total + ${v%.*})); n=$((n + 1))
    [ "${v%.*}" -gt $peak ] && peak=${v%.*}
    sleep 2
  done
  [ $n -eq 0 ] && { echo "$1: process gone"; return; }
  echo "$1: avg $((total / n))% peak ${peak}% (${n} samples)"
}

/tmp/mousemove $CX $NOTCH_Y
sleep 3                              # hover IN first so the hover-OUT
/tmp/mousemove $AWAY_X $AWAY_Y      # collapse transition actually fires
sleep 9                              # (preview starts expanded; without a
measure "collapsed"                 # prior hover-in the panel never collapses)

/tmp/mousemove $CX $NOTCH_Y
sleep 3
measure "expanded"

/tmp/mousemove $AWAY_X $AWAY_Y
kill $APP_PID 2>/dev/null
echo "done (pid $APP_PID, screen ${SW}x${SH})"
