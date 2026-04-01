#!/usr/bin/env bash
#
# Starts reth in dev mode with the stress test genesis.
#
# Environment variables:
#   BLOCK_TIME  — block interval (default: 2000ms)
#   HTTP_PORT   — JSON-RPC port (default: 8545)
#   DATADIR     — reth data directory (default: /tmp/arkiv-stress-reth)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GENESIS="$SCRIPT_DIR/genesis.json"

BLOCK_TIME="${BLOCK_TIME:-2000ms}"
HTTP_PORT="${HTTP_PORT:-8545}"
DATADIR="${DATADIR:-/tmp/arkiv-stress-reth}"

if ! command -v reth &>/dev/null; then
    echo "ERROR: reth not found in PATH. Install via nix develop or cargo install reth."
    exit 1
fi

if [[ ! -f "$GENESIS" ]]; then
    echo "ERROR: $GENESIS not found. Run bootstrap.sh first."
    exit 1
fi

echo "==> Starting reth dev node..."
echo "    Block time:  $BLOCK_TIME"
echo "    HTTP port:   $HTTP_PORT"
echo "    Data dir:    $DATADIR"
echo "    Genesis:     $GENESIS"

reth node \
    --dev \
    --dev.block-time "${BLOCK_TIME}" \
    --datadir "$DATADIR" \
    --http \
    --http.api eth,net,web3,debug,trace \
    --http.addr 0.0.0.0 \
    --http.port "$HTTP_PORT" \
    --chain "$GENESIS" \
    &

RETH_PID=$!
echo "$RETH_PID" > "$SCRIPT_DIR/reth.pid"

echo "==> Waiting for reth to become ready on port $HTTP_PORT..."
RPC_URL="http://127.0.0.1:$HTTP_PORT"
for i in $(seq 1 60); do
    if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
        CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
        echo "==> reth is ready (chain ID: $CHAIN_ID, PID: $RETH_PID)"
        exit 0
    fi
    sleep 0.5
done

echo "ERROR: reth did not become ready within 30 seconds"
kill "$RETH_PID" 2>/dev/null || true
exit 1
