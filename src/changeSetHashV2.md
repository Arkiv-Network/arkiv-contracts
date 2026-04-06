# Change Set Hash (V2)

## Purpose

The change set hash is a verification mechanism that ensures the Arkiv node's database component stays in sync with the EntityRegistry smart contract. It provides:

1. **Integrity verification** — a single `bytes32` commits to every field of every entity mutation
2. **Ordering verification** — the hash chain captures the precise sequence of all mutations
3. **Per-block verification** — syncing nodes can verify correctness at every block boundary

## Architecture Overview

The mechanism spans two components:

```
┌─────────────────────────────────────────────────────────────────────┐
│                           Arkiv Node                                │
├────────────────────────────┬────────────────────────────────────────┤
│   Execution Client (EVM)   │         Database Component             │
│                            │                                        │
│   EntityRegistry Contract  │   Entity Storage (payload, attrs)      │
│   ├─ _changeSetHash        │   ├─ entities table                    │
│   ├─ _lastMutationBlock    │   └─ block_hashes table                │
│   ├─ _changeSetHashAtBlock │       ├─ block_number                  │
│   │   (internal, lazy)     │       ├─ change_set_hash               │
│   └─ changeSetHashAt()     │       └─ last_mutation_block           │
│       (public view)        │                                        │
├────────────────────────────┴────────────────────────────────────────┤
│                                                                     │
│   Verification: contract.changeSetHashAt(N) == db.change_set_hash   │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

Both components independently compute the same change set hash. A match at any block boundary proves the DB has processed every mutation correctly up to that point.

## Smart Contract Design

### Chain Model

Arkiv db-chains do not support arbitrary smart contract deployments. The EntityRegistry is a system contract — one of the few contracts deployed on the chain. This architectural constraint simplifies entity operation detection:

- All entity operations originate from EOA transactions directly targeting EntityRegistry
- Detection is simply: `tx.to == EntityRegistry && tx succeeded`
- No need to trace internal calls or parse logs for cross-contract interactions

This model ensures deterministic, efficient operation detection without the complexity of arbitrary contract composition.

### State Variables

```solidity
// Running hash over the full ordered sequence of entity mutations
bytes32 internal _changeSetHash;

// Last block that had entity mutations (for lazy finalization)
uint256 internal _lastMutationBlock;

// Per-block snapshot for sync verification (lazily populated, internal)
mapping(uint256 blockNumber => bytes32 changeSetHash) internal _changeSetHashAtBlock;
```

### Hash Accumulation

On every entity mutation:

```solidity
function _accumulateChangeSet(Op op, bytes32 _entityKey, bytes32 _entityHash) internal {
    // Lazy finalization: write previous block's hash when entering a new block
    if (block.number != _lastMutationBlock) {
        _changeSetHashAtBlock[_lastMutationBlock] = _changeSetHash;
        _lastMutationBlock = block.number;
    }
    
    // Update running hash
    _changeSetHash = keccak256(abi.encodePacked(_changeSetHash, op, _entityKey, _entityHash));
}
```

### Query Interface

The canonical way to query the change set hash at any block:

```solidity
/// @notice Returns the change set hash at a specific block number.
/// @dev Handles lazy finalization: returns from mapping for finalized blocks,
///      or current hash for the latest mutation block and beyond.
function changeSetHashAt(uint256 blockNumber) public view returns (bytes32) {
    if (blockNumber >= _lastMutationBlock) {
        return _changeSetHash;
    }
    return _changeSetHashAtBlock[blockNumber];
}

/// @notice Returns the current cumulative change set hash.
function changeSetHash() public view returns (bytes32) {
    return _changeSetHash;
}

/// @notice Returns the last block number that had entity mutations.
function lastMutationBlock() public view returns (uint256) {
    return _lastMutationBlock;
}
```

Callers should use `changeSetHashAt(blockNumber)` for verification. This function:
- Returns `_changeSetHash` for the latest mutation block or any block after (chain has been quiet)
- Returns from the mapping for earlier finalized blocks
- Returns `bytes32(0)` for blocks before any mutations occurred

Where:
- `_changeSetHash`: the previous accumulated hash (starts at `bytes32(0)`)
- `op`: the mutation type (`CREATE`, `UPDATE`, `EXTEND`, `TRANSFER`, `DELETE`, `EXPIRE`)
- `entityKey`: the unique identifier of the entity being mutated
- `entityHash`: the EIP-712 hash of the entity's state after the mutation

### Per-Block Mapping (Internal)

The internal `_changeSetHashAtBlock` mapping stores the change set hash at every block that contains entity mutations. It is accessed through the `changeSetHashAt()` view function, which handles lazy finalization. This enables:

- **O(1) verification** at any historical block
- **Sync progress tracking** for nodes catching up to chain head
- **Divergence detection** at block granularity

#### Lazy Finalization

To avoid paying SSTORE costs for every mutation within a block, the mapping is updated lazily: a block's hash is written only when the *next* block's first mutation occurs. This means:

- **Cost**: One SSTORE per block with mutations (not per mutation)
- **Trade-off**: The mapping is "one block behind" — the current block's hash is not in the mapping until the next block's first mutation triggers finalization

The `changeSetHashAt(blockNumber)` view function abstracts this complexity:
- Callers don't need to know whether a block is finalized or not
- The function returns the correct hash for any block number
- No need to distinguish between "query mapping" vs "query current hash"

Blocks without entity mutations have no entry in the mapping. The hash value for such blocks equals the most recent block with mutations — callers should only query blocks they know had mutations.

#### Design Rationale

The smart contract is gas-optimized: it stores only at blocks with mutations. The DB component has cheap storage and maintains complete per-block history. This separation is intentional — the chain provides the minimum necessary for trustless verification, the DB provides everything useful for operations.

## Database Component Design

### Block-Level Tracking

The DB component maintains a table with one row per processed block:

| Column | Type | Description |
|--------|------|-------------|
| `block_number` | uint64 | The block number |
| `change_set_hash` | bytes32 | Accumulated hash after this block |
| `last_mutation_block` | uint64 | Most recent block with entity ops |

This table is populated at the end of every block, regardless of whether the block contained entity mutations.

#### Why Complete Per-Block Tracking

The smart contract stores hashes only at blocks with mutations (gas-optimized). The DB component stores every block (storage is cheap). Benefits of per block hashes:

1. **Operational convenience** — "What was changeSetHash at block X?" answered instantly from local DB without smart contract query

2. **Debugging** — If hashes diverge, binary search on `block_hashes` table to find the exact block where divergence started

3. **Monitoring** — Track EntityRegistry activity patterns over time (mutations per block, quiet periods, etc.)

4. **Defense in depth** — If there's a bug in the "was there an EntityRegistry tx in this block?" detection logic, the DB catches it at the next mutation block when hashes mismatch. The complete per-block table provides an audit trail to investigate.

5. **Gap verification** — For blocks without mutations, the DB can verify its hash equals the previous block's hash. The smart contract can't provide this (no entry exists), but the DB's complete table can.

### Processing Flow

For each block:

1. **Block start**: Begin DB transaction
2. **Per transaction**: 
   - Execute transaction in EVM
   - Check execution result (success/revert)
   - If `tx.to == EntityRegistry` AND successful: forward entity ops to DB component, update running hash
   - If reverted or not targeting EntityRegistry: skip DB component
3. **Block end**: 
   - Insert row into `block_hashes` table
   - If block had mutations: verify `change_set_hash == contract.changeSetHashAt(block_number)`
   - Commit DB transaction (or abort on mismatch)

Note: Since Arkiv db-chains don't support arbitrary contract deployments, all entity operations are direct EOA → EntityRegistry transactions. Detection is simply checking `tx.to` and receipt status — no internal call tracing required.

### Verification During Sync

A syncing node verifies correctness block-by-block:

```
For each block N:
  1. Process all successful transactions targeting EntityRegistry, compute change_set_hash
     (each tx may contain multiple entity ops via batch functions)
  2. If block had mutations:
       assert(change_set_hash == contract.changeSetHashAt(N))
  3. If block had no mutations:
       assert(change_set_hash == previous block's change_set_hash)
```

The `changeSetHashAt(blockNumber)` function handles lazy finalization internally — callers don't need to distinguish between finalized and unfinalized blocks.

The smart contract's `changeSetHashAt()` provides verification anchors for blocks with mutations. The DB's complete per-block table fills the gaps for blocks without mutations.

## Commitment Depth

The change set hash transitively commits to every field of every entity through the EIP-712 hash structure:

```
changeSetHash
├─ previous changeSetHash          ← full history of all prior mutations
├─ op                               ← mutation type (CREATE, UPDATE, EXTEND, TRANSFER, DELETE, EXPIRE)
├─ entityKey                        ← identity of the entity being mutated
└─ entityHash                       ← EIP-712 hash of the entity's full state
     ├─ coreHash                    ← EIP-712 hash of immutable entity content
     │    ├─ entityKey
     │    ├─ creator
     │    ├─ createdAt
     │    ├─ contentType
     │    ├─ keccak256(payload)     ← commits to the full payload content
     │    └─ keccak256(attributeHashes[])
     │         └─ per attribute:
     │              ├─ name
     │              ├─ valueType
     │              ├─ fixedValue
     │              └─ keccak256(stringValue)
     ├─ owner
     ├─ updatedAt
     └─ expiresAt
```

Any divergence — a single byte in a payload, a different attribute value, a wrong owner — propagates through the hash tree and causes a mismatch.

## Trust Model

The verification mechanism relies on the following trust assumptions:

1. **Ethereum consensus** — all nodes agree on transaction ordering and inclusion per block
2. **EVM determinism** — identical transactions produce identical state transitions
3. **Local execution client** — the node runs its own execution client (not a third-party RPC)
4. **No arbitrary contracts** — only system contracts (including EntityRegistry) are deployed; all entity operations are direct EOA transactions

The change set hash extends Ethereum's state verification to the off-chain DB. Just as all execution clients converge on the same state root, all Arkiv nodes converge on the same change set hash.

## Verification Scenarios

### Steady State (Node at Chain Head)

At every new block:
1. DB processes any successful EntityRegistry ops
2. DB computes updated change set hash
3. If block had mutations: verify `change_set_hash == contract.changeSetHashAt(block_number)`
4. Match → commit block; Mismatch → halt and investigate

The `changeSetHashAt()` function handles lazy finalization internally — the same call works whether the block is finalized or the latest mutation block.

### Initial Sync (New Node Catching Up)

For each historical block:
1. Execution client provides authoritative tx list for the block
2. DB processes successful EntityRegistry ops in order
3. For blocks with mutations: verify `change_set_hash == contract.changeSetHashAt(block_number)`
4. For blocks without mutations: no verification needed (Ethereum consensus guarantees no EntityRegistry activity)
5. Continue to next block

The `changeSetHashAt()` function handles all cases uniformly — syncing nodes don't need to know whether they're catching up or at chain head.

### Divergence Recovery

If a mismatch is detected:
1. Identify the last matching block via binary search on `block_hashes` table
2. Replay from that block, comparing per-block hashes
3. Find the first diverging mutation
4. Investigate root cause (bug, data corruption, etc.)

## Gas Cost

- **Per mutation**: ~5k-20k gas for the running hash SSTORE (warm/cold)
- **Per block with mutations**: One SSTORE for `_changeSetHashAtBlock` mapping (via lazy finalization)
- **Per block transition**: One SSTORE for `_lastMutationBlock` update (~5k gas warm)

Without lazy finalization, writing `_changeSetHashAtBlock` on every mutation would cost ~5k gas each. For a block with 100 mutations, that's ~500k gas wasted. Lazy finalization reduces this to a single write per block.

For entities with 120KB payloads (~1.9M gas in calldata alone), the per-block storage cost is negligible.
