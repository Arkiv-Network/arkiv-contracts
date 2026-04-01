#!/usr/bin/env bash
#
# Starts reth in dev mode.
#
# Environment variables:
#   BLOCK_TIME  — block interval (default: 2000ms)
#   HTTP_PORT   — JSON-RPC port (default: 8545)
#   DATADIR     — reth data directory (default: /tmp/arkiv-stress-reth)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BLOCK_TIME="${BLOCK_TIME:-2000ms}"
HTTP_PORT="${HTTP_PORT:-8545}"
DATADIR="${DATADIR:-/tmp/arkiv-stress-reth}"
RPC_URL="http://127.0.0.1:$HTTP_PORT"

if ! command -v reth &>/dev/null; then
    echo "ERROR: reth not found in PATH. Install via nix develop or cargo install reth."
    exit 1
fi

# Kill any existing reth on this port
if [[ -f "$SCRIPT_DIR/reth.pid" ]]; then
    OLD_PID=$(cat "$SCRIPT_DIR/reth.pid")
    kill "$OLD_PID" 2>/dev/null || true
    sleep 1
fi

# Clean datadir for a fresh chain
rm -rf "$DATADIR"

echo "==> Starting reth dev node..."
echo "    Block time:  $BLOCK_TIME"
echo "    HTTP port:   $HTTP_PORT"
echo "    Data dir:    $DATADIR"

reth node \
    --dev \
    --dev.block-time "${BLOCK_TIME}" \
    --datadir "$DATADIR" \
    --http \
    --http.api eth,net,web3,debug,trace \
    --http.addr 127.0.0.1 \
    --http.port "$HTTP_PORT" \
    &

RETH_PID=$!
echo "$RETH_PID" > "$SCRIPT_DIR/reth.pid"

echo "==> Waiting for reth (PID: $RETH_PID)..."
for i in $(seq 1 60); do
    if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

if ! cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    echo "ERROR: reth did not become ready within 30 seconds"
    kill "$RETH_PID" 2>/dev/null || true
    exit 1
fi

CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
echo "==> reth is ready (chain ID: $CHAIN_ID, PID: $RETH_PID)"
echo ""
echo "Run stress test:"
echo "  cd stress && cargo run -- --rpc-url $RPC_URL"
echo ""
echo "Ctrl+C to stop."

cleanup() {
    echo ""
    echo "==> Stopping reth (PID: $RETH_PID)..."
    kill "$RETH_PID" 2>/dev/null || true
    wait "$RETH_PID" 2>/dev/null || true
    rm -f "$SCRIPT_DIR/reth.pid"
    echo "==> Stopped."
}
trap cleanup INT TERM

wait "$RETH_PID"
