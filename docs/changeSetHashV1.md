# Change Set Hash

## Purpose

The change set hash is a single `bytes32` value that commits to the full ordered sequence of every entity mutation that has ever occurred through the EntityRegistry contract. It allows the off-chain DB to verify it has processed every mutation in the correct order with a single `eth_call`.

## Design

A single accumulator, updated on every mutation:

```
changeSetHash = keccak256(changeSetHash || op || entityKey || entityHash)
```

Where:
- `changeSetHash`: the previous accumulated hash (starts at `bytes32(0)`)
- `op`: the mutation type (`CREATE`, `UPDATE`, `EXTEND`, `DELETE`, `EXPIRE`)
- `entityKey`: the entity being mutated
- `entityHash`: the entity's hash after the mutation (or before, for deletes)

## Why a Single Accumulator

The original spec proposed a two-level structure: a per-block hash that accumulates mutations within a block, and a cumulative hash that folds in completed blocks at block boundaries. This was reconsidered for the following reasons.

### The per-op chain already captures everything

Each mutation chains onto the previous hash. After N mutations across any number of blocks, the hash is a deterministic function of the full ordered sequence. Block boundaries add no information — the ordering is already fully captured by the sequential chaining.

### Block grouping is redundant for integrity checking

The off-chain DB processes events sequentially, one mutation at a time. It doesn't process "blocks" — it processes individual `EntityCreated`, `EntityUpdated`, etc. events. The DB computes the same running hash as it processes each event. At any point it can compare its hash against the contract's. If they match, every mutation was processed in order. If not, the DB replays events to find the divergence.

Block-level checkpointing ("at which block did we diverge?") can be done off-chain by recording the hash after the last event in each block. The contract doesn't need to do this grouping.

### The two-level structure added complexity for no benefit

The per-block design required:
- Three state variables (`currentBlockChangeSetHash`, `cumulativeChangeSetHash`, `lastMutationBlock`)
- Block boundary detection logic on every mutation
- A finalization step that folds the block hash into the cumulative hash
- A view function with conditional logic to resolve the "one block behind" lag
- An event (`ChangeSetHashFinalized`) to signal block finalization
- Extra SSTOREs on block transitions (resetting the per-block hash, writing the cumulative hash)

The single accumulator requires:
- One state variable (`_changeSetHash`)
- One SSTORE per mutation
- A trivial view function

### Gas cost

Both designs pay one SSTORE per mutation for the running hash (~5000 gas warm, ~20000 gas cold for the first write in a transaction). The two-level design paid additional SSTOREs on block boundaries for finalization. The single accumulator is strictly cheaper.

### No synchronisation ambiguity

The two-level design had a "one block behind" problem: `cumulativeChangeSetHash` didn't include the current block's mutations until the next block's first mutation triggered finalization. This meant a view function needed conditional logic based on `block.number` to return the correct value, and consumers needed to understand when the value was "complete."

The single accumulator is always up to date. After any mutation, `changeSetHash()` returns the hash covering all mutations up to and including that one. No lag, no conditional logic, no ambiguity.

## Commitment Depth

The change set hash transitively commits to every field of every entity through the EIP-712 hash structure. A single `bytes32` carries the full weight of the entire mutation history:

```
changeSetHash
├─ previous changeSetHash          ← full history of all prior mutations
├─ op                               ← mutation type (CREATE, UPDATE, EXTEND, DELETE, EXPIRE)
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

If any bit of any field — a single byte in a payload, a changed attribute value, a different owner, a wrong block number — differs between the contract and the off-chain DB, the divergence propagates up through the hash tree and the change set hash will not match.

This means the change set hash is not just an ordering check. It is a full integrity commitment over:
- The complete content of every entity (payload, attributes, content type)
- The metadata of every entity (creator, owner, timestamps, expiry)
- The identity of every entity (entity key)
- The type of every mutation (create vs update vs delete, etc.)
- The precise order in which all mutations occurred

## Verification

The off-chain DB verifies sync by:

1. Processing entity mutation events in order
2. Computing `keccak256(hash || op || entityKey || entityHash)` for each event
3. Comparing the result against `changeSetHash()` via `eth_call`

If the values match, the DB has processed every mutation in the correct order. If they diverge, the DB replays events to locate the first mismatch.

## What It Does Not Do

- **Block-level checkpointing**: the contract does not track which block a mutation occurred in. The DB can derive this from event metadata (block number is part of every log).
- **Content validation**: the hash commits to the entity hash, not the entity content. It does not verify payload correctness.
- **Rollback detection**: the hash is append-only. It does not detect chain reorganisations — that is the DB's responsibility via standard reorg handling.
