#!/usr/bin/env bash
#
# Generate an arkiv genesis.json for reth.
#
# Deploys EntityRegistry on a temporary anvil instance to get runtime bytecode
# with correctly populated immutables, then assembles a genesis JSON that
# includes the contract at the predeploy address plus dev accounts.
#
set -euo pipefail

PREDEPLOY_ADDR="0x4200000000000000000000000000000000000042"
CHAIN_ID=1337
RPC_URL="http://localhost:8545"
OUTFILE="${1:-genesis.json}"

# Well-known private key for account 0 of the test mnemonic
# "test test test test test test test test test test test junk"
DEPLOYER_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478c6b8d6c1f02960247590a993"

# Start anvil in background on a random available port
ANVIL_PORT=48545
RPC_URL="http://localhost:${ANVIL_PORT}"

echo "Starting anvil on port ${ANVIL_PORT}..."
anvil --chain-id "$CHAIN_ID" --port "$ANVIL_PORT" --silent &
ANVIL_PID=$!

cleanup() {
    kill "$ANVIL_PID" 2>/dev/null || true
    wait "$ANVIL_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Wait for anvil to be ready
for i in $(seq 1 30); do
    if cast chain-id --rpc-url "$RPC_URL" &>/dev/null; then
        break
    fi
    sleep 0.1
done

# Deploy EntityRegistry
echo "Deploying EntityRegistry..."
DEPLOY_OUTPUT=$(forge create src/EntityRegistry.sol:EntityRegistry \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_KEY" \
    --json)

DEPLOYED_ADDR=$(echo "$DEPLOY_OUTPUT" | jq -r '.deployedTo')
echo "Deployed to: ${DEPLOYED_ADDR}"

# Get runtime bytecode (includes correctly populated immutables)
BYTECODE=$(cast code "$DEPLOYED_ADDR" --rpc-url "$RPC_URL")
echo "Got runtime bytecode (${#BYTECODE} chars)"

# Get the 20 dev accounts from anvil
# These are the standard accounts from the test mnemonic
DEV_ACCOUNTS=(
    "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
    "0x70997970C51812dc63012764C85F7FAb87B63024"
    "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"
    "0x90F79bf6EB2c4f870365E785982E1f101E93b906"
    "0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65"
    "0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc"
    "0x976EA74026E726554dB657fA54763abd0C3a0aa9"
    "0x14dC79964da2C08dA15Fd353d30d9CBa8C7C3F04"
    "0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f"
    "0xa0Ee7A142d267C1f36714E4a8F75612F20a79720"
    "0xBcd4042DE499D14e55001CcbB24a551F3b954096"
    "0x71bE63f3384f5fb98995898A86B02Fb2426c5788"
    "0xFABB0ac9d68B0B445fB7357272Ff202C5651694a"
    "0x1CBd3b2770909D4e10f157cABC84C7264073C9Ec"
    "0xdF3e18d64BC6A983f673Ab319CCaE4f1a57C7097"
    "0xcd3B766CCDd6AE721141F452C550Ca635964ce71"
    "0x2546BcD3c84621e976D8185a91A922aE77ECEc30"
    "0xbDA5747bFD65F08deb54cb465eB87D40e51B197E"
    "0xdD2FD4581271e230360230F9337D5c0430Bf44C0"
    "0x8626f6940E2eb28930eFb4CeF49B2d1F2C9C1199"
)

# Balance: 1,000,000 ETH in hex
DEV_BALANCE="0xD3C21BCECCEDA1000000"

# Build the alloc section
ALLOC="{"

# Add dev accounts
for addr in "${DEV_ACCOUNTS[@]}"; do
    ALLOC+="\"${addr}\": {\"balance\": \"${DEV_BALANCE}\"},"
done

# Add EntityRegistry at predeploy address
# Note: immutables have _cachedThis set to the anvil deploy address, not the
# predeploy address. OZ EIP-712 handles this via fallback recomputation.
ALLOC+="\"${PREDEPLOY_ADDR}\": {\"balance\": \"0x0\", \"nonce\": \"0x1\", \"code\": \"${BYTECODE}\"}"
ALLOC+="}"

# Assemble genesis JSON
cat > "$OUTFILE" << EOF
{
  "config": {
    "chainId": ${CHAIN_ID},
    "homesteadBlock": 0,
    "daoForkSupport": true,
    "eip150Block": 0,
    "eip155Block": 0,
    "eip158Block": 0,
    "byzantiumBlock": 0,
    "constantinopleBlock": 0,
    "petersburgBlock": 0,
    "istanbulBlock": 0,
    "berlinBlock": 0,
    "londonBlock": 0,
    "terminalTotalDifficulty": "0x0",
    "terminalTotalDifficultyPassed": true,
    "shanghaiTime": 0,
    "cancunTime": 0,
    "pragueTime": 0,
    "osakaTime": 0
  },
  "nonce": "0x0",
  "timestamp": "0x0",
  "extraData": "0x",
  "gasLimit": "0x1c9c380",
  "difficulty": "0x0",
  "mixHash": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "coinbase": "0x0000000000000000000000000000000000000000",
  "alloc": ${ALLOC},
  "number": "0x0"
}
EOF

# Pretty-print the JSON
python3 -c "import json, sys; data = json.load(open('${OUTFILE}')); json.dump(data, open('${OUTFILE}', 'w'), indent=2)"

echo "Genesis written to ${OUTFILE}"
echo "EntityRegistry at ${PREDEPLOY_ADDR}"
echo "Chain ID: ${CHAIN_ID}"
echo "Dev accounts: ${#DEV_ACCOUNTS[@]} prefunded with 1M ETH each"
