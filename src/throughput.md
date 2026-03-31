# EntityRegistry Throughput Model

This document models the theoretical throughput of the EntityRegistry contract on a dedicated Optimism L2 chain with a 60M block gas limit and 2-second block time.

## Gas Cost Breakdown

Every operation pays three categories of gas: storage (SSTOREs/SLOADs), hashing (keccak256), and calldata (16 gas per non-zero byte). Which category dominates depends on the operation type and payload size.

### Storage Costs

Entity storage uses 3 EVM storage slots per entity:

| Slot | Contents | Size |
|------|----------|------|
| 0 | creator (20B) + createdAt (4B) + updatedAt (4B) + expiresAt (4B) | 32 bytes |
| 1 | owner (20B) | 20 bytes + 12 padding |
| 2 | coreHash (32B) | 32 bytes |

Key EVM storage costs (EIP-2929):

| Operation | Gas |
|-----------|-----|
| SLOAD (cold, first access to slot in tx) | 2,100 |
| SLOAD (warm, subsequent access) | 100 |
| SSTORE (zero to non-zero, cold) | 22,100 |
| SSTORE (non-zero to non-zero, warm) | 2,900 |
| SSTORE (non-zero to zero, warm) | ~300 + refund |

A new entity CREATE writes 3 slots from zero to non-zero: **66,300 gas**. This is the floor cost for any CREATE regardless of payload size. It cannot be optimised away — it is inherent to the EVM storage model.

### changeSetHash: Batch-Bounded Accumulation

The change set hash is accumulated on the stack within `execute`, not written to storage per operation. One SLOAD at the start of the batch, one SSTORE at the end. Per-operation cost is ~50 gas (one keccak256 on the stack).

| Batch size | Old (per-op SSTORE) | Current (batch-bounded) | Savings |
|---|---|---|---|
| 1 op | 2,900 | 2,900 | 0 |
| 10 ops | 29,000 | 3,400 | 25,600 (88%) |
| 50 ops | 145,000 | 5,400 | 139,600 (96%) |
| 100 ops | 290,000 | 7,900 | 282,100 (97%) |

For batched metadata operations (extend/delete/expire), this removes the dominant cost of integrity checking.

### Per-Operation Gas

All costs assume warm access (not the first operation in a transaction) and batch-bounded changeSetHash accumulation. First-operation cold costs add ~25,000 gas one-time for nonce, changeSetHash, and contentType mapping slots.

#### CREATE

| Component | Empty payload | 1KB payload, 5 attrs | 100KB payload, 10 attrs |
|-----------|--------------|----------------------|------------------------|
| Entity storage (3 new slots) | 66,300 | 66,300 | 66,300 |
| changeSetHash (stack keccak) | ~50 | ~50 | ~50 |
| Nonce SSTORE | 3,000 | 3,000 | 3,000 |
| Content type SLOAD | 100 | 100 | 100 |
| Hashing (payload + attrs + coreHash + entityHash) | ~900 | ~4,000 | ~25,000 |
| Event emission | ~2,100 | ~2,100 | ~2,100 |
| Calldata | ~4,600 | ~24,000 | ~1,600,000 |
| **Total** | **~75,000** | **~97,000** | **~1,700,000** |

Entity storage dominates for small payloads. Calldata dominates above ~5KB.

#### UPDATE

Same as CREATE for hashing and calldata, but cheaper storage — only 2 slots change (coreHash + updatedAt) instead of 3 new slots:

| Component | 1KB payload, 5 attrs |
|-----------|---------------------|
| Entity SLOADs (3 slots, cold) | 6,300 |
| Entity SSTOREs (2 slots, warm) | 5,800 |
| changeSetHash (stack keccak) | ~50 |
| Hashing | ~4,000 |
| Calldata | ~24,000 |
| **Total** | **~40,000** |

#### EXTEND

No payload, no attributes. Only reads the entity and writes 2 fields:

| Component | Gas |
|-----------|-----|
| Entity SLOADs (2 slots, cold) | 4,200 |
| Entity SSTOREs (expiresAt + updatedAt) | 5,800 |
| changeSetHash (stack keccak) | ~50 |
| entityHash computation | ~500 |
| Calldata | ~4,600 |
| **Total** | **~15,000** |

#### DELETE

Reads entity, computes hash, clears 3 storage slots:

| Component | Gas |
|-----------|-----|
| Entity SLOADs (3 slots, cold) | 6,300 |
| Entity SSTOREs (3 slots to zero) | ~300 + refund |
| changeSetHash (stack keccak) | ~50 |
| entityHash computation | ~500 |
| Calldata | ~4,600 |
| **Total** | **~12,000** |

#### EXPIRE

Same as DELETE but no owner check (saves one comparison, negligible):

| Component | Gas |
|-----------|-----|
| Total | **~10,000** |

## Throughput Per Block

Given a 60M block gas limit, with batch operations amortising the 21,000 base transaction cost and the changeSetHash SLOAD/SSTORE:

| Scenario | Per-op gas | Ops per block | Ops per second (2s blocks) |
|----------|-----------|---------------|---------------------------|
| Minimal CREATEs (empty payload) | ~75,000 | ~800 | ~400 |
| Small CREATEs (1KB, 5 attrs) | ~97,000 | ~618 | ~309 |
| Medium CREATEs (10KB, 5 attrs) | ~247,000 | ~242 | ~121 |
| Large CREATEs (100KB, 10 attrs) | ~1,700,000 | ~35 | ~17 |
| UPDATEs (1KB, 5 attrs) | ~40,000 | ~1,500 | ~750 |
| EXTENDs | ~15,000 | ~4,000 | ~2,000 |
| DELETEs | ~12,000 | ~5,000 | ~2,500 |
| EXPIREs | ~10,000 | ~6,000 | ~3,000 |

## Cost Dominance by Payload Size

The crossover point where calldata cost exceeds storage cost:

```
Entity storage floor:  ~69,000 gas (3 new slots + nonce)
Calldata cost:         ~16 gas per byte

Crossover: 69,000 / 16 ≈ 4,300 bytes (~4.3KB)
```

Below ~4.3KB, storage dominates. Above ~4.3KB, calldata dominates. For large payloads (100KB+), calldata is 90%+ of the total gas cost.

## changeSetHash Overhead

With batch-bounded accumulation, the changeSetHash cost per operation is ~50 gas (stack keccak256) plus the amortised SLOAD/SSTORE (~2,900 / batch size). As a fraction of total cost for a batch of 10:

| Operation | changeSetHash cost | % of total |
|-----------|--------------------|-----------|
| CREATE (1KB) | ~340 | 0.4% |
| UPDATE (1KB) | ~340 | 0.9% |
| EXTEND | ~340 | 2.3% |
| DELETE | ~340 | 2.8% |
| EXPIRE | ~340 | 3.4% |

For single-op transactions, the cost is ~2,950 gas (full SLOAD + keccak + SSTORE). For batches of 10+, the integrity check is effectively free.

## Scaling Levers

If throughput is insufficient, the following parameters can be adjusted on the dedicated chain:

| Lever | Effect | Trade-off |
|-------|--------|-----------|
| Increase block gas limit | Linear throughput increase | Longer block execution, higher node hardware requirements |
| Decrease block time | More blocks per second | Tighter propagation timing, higher bandwidth requirements |
| Payload via DA layer | Calldata cost drops to ~0 for payload (only hash in calldata) | Adds external DA dependency, changes contract interface |
| Batch larger | Amortises base tx cost and changeSetHash SSTORE | Single point of failure (one bad op reverts all) |

The most impactful lever for large payloads is separating the payload from calldata — passing only `bytes32 payloadHash` to the contract and committing the payload to a DA layer. This eliminates the calldata cost entirely, making every CREATE cost ~75,000 gas regardless of payload size. At that cost, the system could handle ~400 creates/second of any size.
