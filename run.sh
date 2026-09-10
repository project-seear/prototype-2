#!/bin/bash
# Build and run the experiment. Data goes to ./data.
#
# The app is launched with `open` rather than by executing the binary directly:
# CoreMotion's permission (and the Motion & Fitness entry in System Settings) is
# attributed to the launching process, so running the binary from a shell would
# ask for the *terminal's* motion access instead of the app's.
#
# `open --stdout` cannot take /dev/stdout (LaunchServices rejects it with
# -10810), so the app logs to a file and we tail it to keep the per-trial lines
# in this terminal.
#
# Any arguments are passed through to the app, e.g.
#   ./run.sh --mode random --trials 10
set -euo pipefail
cd "$(dirname "$0")"
[ "${SKIP_BUILD:-0}" = "1" ] || ./build.sh
mkdir -p data

LOG="data/session_$(date +%Y%m%d_%H%M%S).log"
: > "$LOG"
echo "==> data directory: $PWD/data"
echo "==> log:            $PWD/$LOG"
echo

tail -f "$LOG" &
TAIL_PID=$!
trap 'kill "$TAIL_PID" 2>/dev/null || true' EXIT INT TERM

open -W --env "P2_DATA_DIR=$PWD/data" --stdout "$LOG" --stderr "$LOG" \
     "$PWD/build/Prototype2.app" ${1+--args "$@"}

sleep 0.3            # let tail flush the last lines before it is killed
kill "$TAIL_PID" 2>/dev/null || true
echo
echo "==> finished. CSVs and summary in $PWD/data"
