# Blob-Based Payload Model

This document evaluates replacing calldata payloads with EIP-4844 blob sidecars in the EntityRegistry contract on a dedicated Optimism L2 chain.

## 1. Current Model: Calldata Payloads

### How it works

The EntityRegistry accepts file uploads as `bytes payload` in the `Op` struct. The full payload is passed as calldata, hashed via `keccak256(payload)`, and the hash is embedded in the entity's `coreHash`. The payload itself is never stored on-chain — only the 32-byte hash persists in the entity's state.

```
Client → execute(Op{ payload: [file bytes] }) → keccak256(payload) → coreHash → storage
                                                  ↑ full file in calldata
                                                  ↑ ~16 gas per non-zero byte
```

The payload contributes to the EIP-712 hash chain:

```
changeSetHash
└─ entityHash
   └─ coreHash
      └─ keccak256(payload)   ← file content commitment
```

### Cost analysis (stress test results)

Measured on a reth dev node with 60M block gas limit, 2s blocks. Costs projected to Optimism L2 economics (L2 gas: 0.001 gwei, L1 data: 5 gwei/byte, ETH: $2000).

| File Size | Calldata | Gas Used | L2 Exec Cost | L1 Data Cost | Total (USD) |
|-----------|----------|----------|--------------|--------------|-------------|
| 1 KB | 2 KB | 181K | $0.0004 | $0.02 | $0.02 |
| 10 KB | 11 KB | 298K | $0.0006 | $0.11 | $0.11 |
| 100 KB | 101 KB | 1.8M | $0.004 | $1.03 | $1.04 |
| 1 MB | 1,001 KB | 18.9M | $0.04 | $10.25 | $10.29 |
| 10 MB | 9.8 MB | ~190M | $0.38 | $100 | ~$103 |

L1 data availability cost dominates at 98-100% of total cost across all file sizes. The L2 execution gas (hashing + storage) is negligible.

For comparison, S3 costs ~$0.001 for 10MB (upload + storage + transfer). The calldata model is approximately **100,000x more expensive** than commodity storage.

### Why the cost is structural

Every byte of the payload passes through the L2 execution layer as calldata, even though it's only hashed and discarded. The 16 gas per non-zero calldata byte is an intrinsic EVM cost that exists to price data availability — the guarantee that the data was available when the transaction executed.

On Optimism, the L2 execution gas is cheap (0.001 gwei), but the L1 data posting cost is not. The L2 batches its transactions to L1, and every byte of calldata in every L2 transaction contributes to the L1 batch size. The L1 data availability cost is the dominant expense.

### Chunking overhead

Files larger than ~120KB (the gas-limited maximum per transaction at 60M block gas) require chunking across multiple transactions. Each chunk carries:
- 21,000 gas intrinsic transaction cost
- ABI encoding overhead (~900 bytes per chunk)
- Three attributes per chunk: `chunk_idx`, `chunk_total`, `file_hash` (for reassembly)
- A separate `changeSetHash` update per chunk

A 10MB file requires ~79 chunks at 128KB tx size limit, or ~4 chunks at 60M gas limit. Each chunk is an independent entity in the registry, linked by the `file_hash` attribute.

## 2. Proposed Model: Blob Payloads with KZG Commitments

### EIP-4844 overview

EIP-4844 (Cancun upgrade, March 2024) introduces a new transaction type (type 3) that carries "blob sidecars" — large data payloads in a separate data channel from calldata.

Key properties:
- Each blob is exactly 128KB (4096 field elements x 32 bytes)
- Up to 6 blobs per transaction (768KB total)
- Blobs carry KZG polynomial commitments — a cryptographic binding
- The `BLOBHASH` opcode (0x49) returns the versioned hash of a blob during execution
- The point evaluation precompile (address 0x0a) verifies blob contents against commitments
- Blob data is temporary on L1 (pruned after ~18 days) but the commitment is permanent

### How blob payloads would work

```
Client → execute(Op{ blobHash: bytes32, blobIndex: uint8 })
         + blob sidecar attached to transaction

Contract:
  1. blobhash(op.blobIndex) → versioned hash (from EVM)
  2. Verify: blobhash(op.blobIndex) == op.blobHash
  3. coreHash includes op.blobHash (not keccak256(payload))
  4. Store coreHash in entity state (as before)
```

The hash chain becomes:

```
changeSetHash
└─ entityHash
   └─ coreHash
      └─ blobHash   ← KZG commitment (verified by EVM at execution time)
```

### KZG commitment security

The KZG (Kate-Zaverucha-Goldberg) commitment scheme provides:

- **Binding**: Given a commitment, it is computationally infeasible to find two different polynomials (data) that produce the same commitment. The contract can trust that the blobHash uniquely identifies the blob content.
- **Succinctness**: The commitment is 48 bytes regardless of data size (128KB per blob).
- **Verification**: The point evaluation precompile allows on-chain verification of specific values within the blob at specific positions. This is optional for the EntityRegistry (we only need the binding property) but available if needed.

The `blobhash(index)` opcode returns `keccak256(commitment || 0x01)` — a versioned hash that includes the full KZG commitment. This is computed by the execution engine from the actual blob bytes; it cannot be forged without the corresponding blob data.

### Cost comparison

| File Size | Calldata Model | Blob Model | Savings |
|-----------|---------------|------------|---------|
| 1 KB | $0.02 | ~$0.001 | 20x |
| 10 KB | $0.11 | ~$0.001 | 110x |
| 100 KB | $1.04 | ~$0.001 | 1,040x |
| 1 MB | $10.29 | ~$0.01 | 1,029x |
| 10 MB | ~$103 | ~$0.08 | 1,288x |

Blob model costs:
- **L2 execution**: ~75K gas fixed (entity storage + hashing), regardless of payload size = ~$0.0003
- **Blob fee**: ~1 wei/byte on current L1 blob market. On a dedicated L2, configurable to near-zero.
- **Per-file**: ~$0.001 for execution + blob fee proportional to file size

The key difference: the calldata model's cost scales linearly with file size (16 gas/byte). The blob model's execution cost is **constant** (~75K gas) because only the 32-byte blobHash enters the execution layer.

### Chunking in the blob model

Files larger than 128KB still require chunking, but at blob-level granularity:
- Each blob carries up to 128KB of payload
- Up to 6 blobs per transaction = 768KB per transaction
- A 10MB file = 79 blobs = 14 transactions

The chunk attribute model (`chunk_idx`, `chunk_total`, `file_hash`) works the same way, but each chunk references a blob instead of calldata.

## 3. Trust Model

### What the chain guarantees (trustless)

| Property | Mechanism | Trust level |
|----------|-----------|-------------|
| Commitment binding | KZG math (discrete log assumption) | Cryptographic |
| Execution-time verification | `blobhash()` opcode, computed by EVM | Protocol |
| Commitment permanence | Stored in coreHash → entity state | On-chain |
| Mutation ordering | changeSetHash chain | On-chain |
| Immutability | coreHash cannot be changed after creation (only deleted) | Contract logic |

### What the sequencer guarantees (trusted)

| Property | Mechanism | Trust level |
|----------|-----------|-------------|
| Data availability | Sequencer retains blob data | Operational |
| Correct pruning | Sequencer prunes only after entity expiry | Operational |
| Liveness | Sequencer produces blocks | Operational |

### Attack vectors

**Forgery (impossible)**: A sequencer cannot produce a valid block where `blobhash(n)` returns a hash that doesn't correspond to the actual blob data. The EVM computes the hash from the blob bytes; the math prevents forgery.

**Corruption (impossible)**: Modifying a blob after execution would change its KZG commitment, which would no longer match the on-chain blobHash in the entity's coreHash. Any client can detect this.

**Withholding (possible)**: The sequencer could accept a blob transaction, execute it correctly (commitment goes on-chain), then refuse to serve the blob data afterward. The entity's coreHash would be valid on-chain, but the actual file content would be unavailable.

This withholding risk is **identical** to the current calldata model on a single-sequencer L2. The sequencer is the only entity that stores recent block data; if it refuses to serve historical calldata, the same problem exists.

### Mitigation for withholding

1. **Redundant full nodes**: Run multiple nodes that independently store blob data. If the sequencer withholds, other nodes have copies.
2. **Client-side archival**: The off-chain DB fetches and archives blob data immediately upon receipt. After archival, the DB holds the data independently of the sequencer.
3. **External DA backup**: Archive blobs to Celestia, EigenDA, or S3 at submission time. The on-chain commitment is the authority; the DA layer is the backup.
4. **Detectable failure**: If a client requests blob data and the sequencer doesn't serve it, the client knows (it has the on-chain commitment but no data). This is a detectable failure, not a silent one.

## 4. Sequencer Implementation

### What OP Stack already supports (zero changes)

OP Stack L2s with the Ecotone upgrade (Cancun EVM) already have:

- EIP-4844 transaction type (type 3) in the mempool
- `BLOBHASH` opcode in the execution engine
- Point evaluation precompile at address 0x0a
- Blob gas accounting in block headers
- KZG trusted setup (c-kzg library shipped with the client)

### Configuration changes needed

| Parameter | Default | Recommended | How |
|-----------|---------|-------------|-----|
| Max blobs per block | 6 (768KB) | Application-dependent | Sequencer config |
| Blob base fee | Market-driven | Near-zero (dedicated chain) | Genesis config |
| Blob retention | ~18 days (L1 semantics) | Until entity expiry | Sequencer config |
| Blob RPC endpoints | May be disabled | Enable `eth_getBlobSidecars` | RPC config flag |
| Txpool blob limits | 20MB default | Increase for throughput | `--txpool.blobpool-max-size` |

### Blob retention strategy

Three options, increasing in complexity:

**Option A — Fixed retention window**: Keep all blobs for N days (e.g., 90 days). Simple, predictable storage costs. Entities living longer than N days require the off-chain DB to have cached the data within the window.

**Option B — Contract-aware retention**: A background process reads `EntityRegistry.entities(key).expiresAt` and prunes only after that block. Precise, but couples the sequencer to a specific contract.

**Option C — Client-responsibility model (recommended)**: The sequencer retains blobs for a fixed short window (e.g., 7 days). The off-chain DB is responsible for fetching and archiving blob data within that window. After the window, the sequencer doesn't have it, but the DB does. This is the simplest approach and matches how Ethereum L1 works — consumers of blob data are expected to fetch it before the pruning window.

### Throughput at various configurations

| Blobs/block | Block time | Throughput | Notes |
|-------------|-----------|------------|-------|
| 6 | 2s | 384 KB/s | OP Stack default |
| 16 | 2s | 1 MB/s | Moderate increase |
| 64 | 1s | 8 MB/s | Aggressive |
| 256 | 1s | 32 MB/s | Theoretical max (untested) |

Each blob requires ~1ms for KZG proof generation. At 256 blobs/block, that's 256ms of KZG computation per block — feasible with a 1s block time.

## 5. Smart Contract Changes

### Op struct

```solidity
// Current:
struct Op {
    OpType opType;
    bytes32 entityKey;
    bytes payload;           // full file in calldata
    string contentType;
    Attribute[] attributes;
    BlockNumber expiresAt;
}

// Proposed:
struct Op {
    OpType opType;
    bytes32 entityKey;
    bytes32 blobHash;        // versioned hash from BLOBHASH opcode
    uint8 blobIndex;         // which blob slot (0-5) in this transaction
    string contentType;
    Attribute[] attributes;
    BlockNumber expiresAt;
}
```

### CORE_HASH_TYPEHASH

```solidity
// Current:
bytes32 public constant CORE_HASH_TYPEHASH = keccak256(
    "CoreHash(bytes32 entityKey,address creator,uint32 createdAt,string contentType,bytes payload,Attribute[] attributes)"
    "Attribute(bytes32 name,uint8 valueType,bytes32 fixedValue,string stringValue)"
);

// Proposed:
bytes32 public constant CORE_HASH_TYPEHASH = keccak256(
    "CoreHash(bytes32 entityKey,address creator,uint32 createdAt,string contentType,bytes32 blobHash,Attribute[] attributes)"
    "Attribute(bytes32 name,uint8 valueType,bytes32 fixedValue,string stringValue)"
);
```

### _coreHash function

```solidity
// Current:
function _coreHash(
    bytes32 key, address creator, uint32 createdAt,
    string calldata contentType, bytes calldata payload, bytes32[] memory attrHashes
) internal pure returns (bytes32) {
    return keccak256(abi.encode(
        CORE_HASH_TYPEHASH, key, creator, createdAt,
        keccak256(bytes(contentType)),
        keccak256(payload),                    // ← hashes full payload
        keccak256(abi.encodePacked(attrHashes))
    ));
}

// Proposed:
function _coreHash(
    bytes32 key, address creator, uint32 createdAt,
    string calldata contentType, bytes32 blobHash, bytes32[] memory attrHashes
) internal pure returns (bytes32) {
    return keccak256(abi.encode(
        CORE_HASH_TYPEHASH, key, creator, createdAt,
        keccak256(bytes(contentType)),
        blobHash,                              // ← already a commitment
        keccak256(abi.encodePacked(attrHashes))
    ));
}
```

### _validateAndHash function

```solidity
// Current signature:
function _validateAndHash(
    bytes32 key, address creator, uint32 createdAt,
    string calldata contentType, bytes calldata payload, Attribute[] calldata attributes
) internal view returns (bytes32)

// Proposed signature:
function _validateAndHash(
    bytes32 key, address creator, uint32 createdAt,
    string calldata contentType, bytes32 blobHash, uint8 blobIndex,
    Attribute[] calldata attributes
) internal view returns (bytes32)
```

Added verification:
```solidity
if (blobhash(blobIndex) != blobHash) revert BlobHashMismatch(blobIndex, blobHash);
```

### New error

```solidity
error BlobHashMismatch(uint8 blobIndex, bytes32 expectedHash);
```

### Gas impact

| Operation | Current (1KB payload) | Current (1MB payload) | Blob model (any size) |
|-----------|----------------------|----------------------|-----------------------|
| CREATE | ~97K gas | ~18.9M gas | ~75K gas |
| UPDATE | ~40K gas | ~16M gas | ~40K gas |
| EXTEND | ~15K gas | ~15K gas | ~15K gas (unchanged) |
| DELETE | ~12K gas | ~12K gas | ~12K gas (unchanged) |

The blob model eliminates the payload-size-dependent gas cost entirely. CREATE and UPDATE become fixed-cost operations regardless of file size.

### What stays the same

- Entity struct (stores coreHash — unchanged)
- entityHash computation (wraps coreHash + mutable fields — unchanged)
- changeSetHash accumulation (chains entityHash values — unchanged)
- EXTEND, DELETE, EXPIRE operations (don't touch payload — unchanged)
- Attribute model (unchanged)
- EIP-712 domain separator (unchanged)
- ChangeSetHashUpdated event (unchanged)

## 6. Off-chain Database Sync

### Current sync model (calldata)

```
Chain events                    Off-chain DB
─────────────                   ──────────────
EntityCreated(key, hash, ...)  → Parse calldata from tx to get payload
                                 Store entity + payload
                                 Update local changeSetHash
ChangeSetHashUpdated(hash)     → Compare: local hash == chain hash?
```

The DB must parse transaction calldata to extract the payload, since the payload is not included in the event.

### Blob sync model

```
Chain events                    Off-chain DB
─────────────                   ──────────────
EntityCreated(key, hash, ...)  → Read blobHash from event/calldata
                                 Fetch blob data from sequencer RPC
                                 Verify: KZG commitment matches blobHash
                                 Store entity + blob data
                                 Update local changeSetHash
ChangeSetHashUpdated(hash)     → Compare: local hash == chain hash?
```

The DB fetches blob data separately via `eth_getBlobSidecars(blockNumber)` and verifies the KZG commitment locally.

### Detectable failure modes

| Failure | Detection | Recovery |
|---------|-----------|----------|
| Blob data unavailable | Fetch returns empty, but blobHash exists on-chain | Flag entity as "commitment exists, data missing". Retry from backup DA. |
| Blob data corrupted | KZG verification fails | Reject data, retry from different source |
| Missing event | Local changeSetHash diverges from chain | Re-index from the divergence point |
| Sequencer reorg | changeSetHash changes at a previously synced block | Re-index affected blocks |

The blob model's verification is stronger than the calldata model: the DB verifies a KZG commitment (cryptographic proof), not just a keccak256 hash match. The chain itself verified the blob at execution time — the DB is confirming the same binding.

### Blob data lifecycle matches entity lifecycle

Blob data on the sequencer follows the same lifecycle as entities in the contract:

1. **Entity created** → sequencer has blob data → DB fetches and indexes
2. **Entity active** → sequencer retains blob → DB serves file content
3. **Entity expires** → sequencer prunes blob → DB prunes too

The off-chain DB only needs to index **active entities**. Expired entities are pruned from both the sequencer and the DB simultaneously. There is no requirement to retain blob data beyond entity expiry.

**Re-sync from sequencer**: If the DB goes offline and comes back, it re-syncs from the sequencer's current state. Entities that expired during downtime are already gone from both sides — no gap to fill, no missed data to recover.

**changeSetHash verification without blob data**: The hash chain is computed from `blobHash` values (on-chain permanently), not from blob bytes. The DB can verify its changeSetHash against the chain without needing the actual file content of expired entities. The hash chain proves the complete ordered history of mutations; the blob data is only needed to serve file content for active entities.

**Comparison to calldata model**: In the calldata model, a full archive node retains all historical calldata indefinitely, making it theoretically possible to reconstruct the DB from scratch at any point. In the blob model, this reconstruction is bounded by the sequencer's retention window — only active (non-expired) entities can be reconstructed. This is a feature, not a limitation: the entity's `expiresAt` defines the data retention boundary, and the system respects it at every layer.

## 7. Known Limitations and Trade-offs

### 7.1 Fixed blob size (128KB)

Each blob is exactly 128KB regardless of payload size. A 1KB entity consumes a full 128KB blob. The KZG commitment scheme is built on a fixed-degree polynomial (4096 field elements) with a trusted setup ceremony specific to that degree. Variable-width blobs would require:

- A separate trusted setup per polynomial degree
- A modified or parameterized point evaluation precompile
- Forked cryptographic assumptions incompatible with Ethereum's

This is not feasible without breaking the KZG framework.

**Mitigations:**
- **Sub-blob packing**: Multiple small payloads can share a single blob. The point evaluation precompile can verify values at specific positions within a blob. The Op struct would include a position/offset within the blob rather than claiming the whole blob. This is more complex but works within the existing cryptography.
- **Calldata for small payloads**: Below a threshold (e.g., 4KB where calldata gas < blob overhead), use calldata instead of blobs. This dual-mode approach adds contract complexity but is cost-optimal at every file size. The Op struct would carry either `bytes payload` or `bytes32 blobHash` depending on size.
- **Accept the waste**: On a dedicated L2 with near-zero blob fees, the 128KB minimum is a bandwidth cost, not a financial one. For most workloads this is acceptable.

### 7.2 UPDATE requires a blob transaction

Every UPDATE replaces the payload, requiring a new blob sidecar. Clients must construct type 3 (EIP-4844) transactions for every CREATE and UPDATE, not just for large files. This is a tooling requirement — standard `eth_sendTransaction` with calldata no longer works for payload-bearing operations.

### 7.3 Batch size limited to 6 blobs per transaction

EIP-4844 caps at 6 blobs per transaction (768KB total). In the calldata model, a single `execute([op1, ..., op100])` can batch 100 small creates. With blobs, a batch can carry at most 6 payload-bearing operations. Non-payload operations (EXTEND, DELETE, EXPIRE) are unaffected.

For high-volume small-entity workloads, this reduces batching efficiency. The sub-blob packing approach (7.1) would recover this by fitting multiple entities per blob.

### 7.4 Zero blobHash bypass

`blobhash(n)` returns `bytes32(0)` for non-existent blob indices. If the contract doesn't guard against this, a caller could pass `blobHash = bytes32(0)` with any `blobIndex` beyond the attached blobs, and the verification `blobhash(blobIndex) == blobHash` would pass — creating an entity with a zero commitment and no actual data.

**Required fix:**
```solidity
if (blobHash == bytes32(0)) revert EmptyBlobHash();
```

### 7.5 KZG commitment is not a content hash

The blobHash is `keccak256(kzg_commitment || 0x01)` — a versioned hash of the KZG polynomial commitment, not a direct hash of the file bytes. Two identical files produce the same blobHash (the scheme is deterministic), but the mapping is indirect. The off-chain DB must verify blob data via KZG proof verification, not by hashing bytes and comparing. Client libraries (c-kzg, rust-kzg) handle this transparently.

### 7.6 No post-execution re-verification on-chain

The `blobhash()` opcode is only available during the transaction that carries the blob. After the block is finalized, there is no on-chain mechanism to re-verify that a piece of data matches a stored blobHash — this would require the point evaluation precompile with the original blob data, which may be pruned.

Dispute resolution ("did the sequencer serve the correct data?") can only happen while the blob data exists. After pruning, the commitment is all that remains. For active entities this is not a problem (the sequencer retains the data). For expired entities, the commitment is a permanent proof of existence but the content is gone by design.

### 7.7 Forge testing coverage gap

Forge's `vm.blobhashes()` cheatcode sets blob hashes in the test EVM, enabling testing of the contract's blobhash matching and hash chain logic. However, the full blob submission flow (type 3 transaction construction, KZG proof generation, sidecar propagation) cannot be tested in Forge. End-to-end testing requires an actual Cancun-enabled node (reth or geth).
