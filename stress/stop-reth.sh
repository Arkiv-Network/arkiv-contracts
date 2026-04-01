#!/usr/bin/env bash
#
# Stops the reth dev node and optionally cleans up the data directory.
#
# Usage:
#   ./stop-reth.sh           # stop only
#   ./stop-reth.sh --clean   # stop and remove datadir
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/reth.pid"
DATADIR="${DATADIR:-/tmp/arkiv-stress-reth}"

if [[ -f "$PID_FILE" ]]; then
    PID=$(cat "$PID_FILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "==> Stopping reth (PID: $PID)..."
        kill "$PID"
        wait "$PID" 2>/dev/null || true
        echo "    Stopped."
    else
        echo "==> reth process $PID is not running."
    fi
    rm -f "$PID_FILE"
else
    echo "==> No PID file found. Attempting to find reth process..."
    pkill -f "reth node.*dev" 2>/dev/null && echo "    Stopped." || echo "    No reth process found."
fi

if [[ "${1:-}" == "--clean" ]]; then
    echo "==> Cleaning up data directory: $DATADIR"
    rm -rf "$DATADIR"
    echo "    Done."
fi
