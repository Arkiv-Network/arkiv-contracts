#!/usr/bin/env bash
#
# Generates genesis.json with EntityRegistry pre-deployed.
#
# Workflow:
#   1. Compile contracts (forge build)
#   2. Start Anvil on a temporary port
#   3. Deploy EntityRegistry
#   4. Extract runtime bytecode and storage
#   5. Write stress/genesis.json
#   6. Stop Anvil
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ANVIL_PORT=18545
ANVIL_RPC="http://127.0.0.1:$ANVIL_PORT"

# Well-known Anvil dev account (account 0)
DEV_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
DEV_ADDR="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

# Deterministic contract address: deployer=$DEV_ADDR nonce=0
CONTRACT_ADDR="0x5FbDB2315678afecb367f032d93F642f64180aa3"

# validContentTypes mapping is at storage slot 5
VALID_CT_SLOT=5
CONTENT_TYPES=(
    "application/json"
    "application/octet-stream"
    "application/pdf"
    "application/cbor"
    "text/plain"
    "text/csv"
    "text/html"
)

cleanup() {
    if [[ -n "${ANVIL_PID:-}" ]]; then
        kill "$ANVIL_PID" 2>/dev/null || true
        wait "$ANVIL_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "==> Building contracts..."
cd "$PROJECT_ROOT"
forge build --silent

# Kill any leftover Anvil on this port
if lsof -ti :"$ANVIL_PORT" >/dev/null 2>&1; then
    echo "==> Killing existing process on port $ANVIL_PORT..."
    kill $(lsof -ti :"$ANVIL_PORT") 2>/dev/null || true
    sleep 1
fi

echo "==> Starting Anvil on port $ANVIL_PORT..."
anvil --port "$ANVIL_PORT" --silent &
ANVIL_PID=$!

# Wait for Anvil to be ready
for i in $(seq 1 30); do
    if cast chain-id --rpc-url "$ANVIL_RPC" >/dev/null 2>&1; then
        break
    fi
    sleep 0.2
done

echo "==> Deploying EntityRegistry..."
forge create src/EntityRegistry.sol:EntityRegistry \
    --rpc-url "$ANVIL_RPC" \
    --private-key "$DEV_KEY" \
    --broadcast \
    >/dev/null 2>&1

# Verify deployment at the deterministic address (deployer nonce=0)
CODE_CHECK=$(cast code "$CONTRACT_ADDR" --rpc-url "$ANVIL_RPC")
if [[ "$CODE_CHECK" == "0x" || -z "$CODE_CHECK" ]]; then
    echo "ERROR: No code at expected address $CONTRACT_ADDR"
    exit 1
fi
echo "    Deployed to: $CONTRACT_ADDR"

echo "==> Extracting runtime bytecode..."
CODE=$(cast code "$CONTRACT_ADDR" --rpc-url "$ANVIL_RPC")

echo "==> Reading validContentTypes storage slots..."
STORAGE_JSON=""
for ct in "${CONTENT_TYPES[@]}"; do
    # Mapping key = keccak256(bytes(contentType))
    KEY=$(cast keccak "$(printf '%s' "$ct")")
    # Storage slot = keccak256(abi.encode(key, baseSlot))
    SLOT=$(cast index bytes32 "$KEY" "$VALID_CT_SLOT")
    VALUE=$(cast storage "$CONTRACT_ADDR" "$SLOT" --rpc-url "$ANVIL_RPC")

    if [[ "$VALUE" == "0x0000000000000000000000000000000000000000000000000000000000000000" ]]; then
        echo "    WARNING: $ct slot is zero (expected true)"
    fi

    if [[ -n "$STORAGE_JSON" ]]; then
        STORAGE_JSON="$STORAGE_JSON,"
    fi
    STORAGE_JSON="$STORAGE_JSON
                \"$SLOT\": \"$VALUE\""
done

# Also check EIP-712 fallback strings (slots 0 and 1) — should be empty but read them anyway
for SLOT_NUM in 0 1; do
    SLOT_HEX=$(printf '0x%064x' "$SLOT_NUM")
    VALUE=$(cast storage "$CONTRACT_ADDR" "$SLOT_HEX" --rpc-url "$ANVIL_RPC")
    if [[ "$VALUE" != "0x0000000000000000000000000000000000000000000000000000000000000000" ]]; then
        STORAGE_JSON="$STORAGE_JSON,
                \"$SLOT_HEX\": \"$VALUE\""
    fi
done

echo "==> Generating genesis.json..."

# Pre-fund multiple test accounts with large ETH balances
# Account 0 is the dev/funder account
PREFUNDED_BALANCE="0x200000000000000000000000000000000000000000000000000000000000000"

python3 -c "
import json, sys

with open('$SCRIPT_DIR/genesis-template.json') as f:
    genesis = json.load(f)

genesis['alloc'] = {
    '$CONTRACT_ADDR': {
        'code': '$CODE',
        'storage': {$(echo "$STORAGE_JSON")
        },
        'balance': '0x0'
    },
    '$DEV_ADDR': {
        'balance': '$PREFUNDED_BALANCE'
    }
}

with open('$SCRIPT_DIR/genesis.json', 'w') as f:
    json.dump(genesis, f, indent=2)
    f.write('\n')
"

echo "==> Done. Generated $SCRIPT_DIR/genesis.json"
echo "    Contract address: $CONTRACT_ADDR"
echo "    Dev account:      $DEV_ADDR"
