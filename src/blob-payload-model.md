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

### Current OP Stack: blob transactions are blocked on L2

**Critical finding**: The OP Stack execution engine (op-geth) explicitly rejects type 3 (EIP-4844) blob transactions on L2. In `core/txpool/validation.go`:

```go
if opts.Config.IsOptimism() && tx.Type() == types.BlobTxType {
    return core.ErrTxTypeNotSupported
}
```

This is a deliberate design choice. On the current OP Stack, blobs only flow in the **L1→L2 direction** — the batcher posts blobs to L1, and op-node reads them during derivation. User-submitted blob transactions on L2 are not supported.

The `BLOBHASH` opcode and point evaluation precompile are available in the EVM (Cancun is enabled), but there is no mechanism for L2 transactions to carry blob sidecars.

### What the OP Stack does support (no changes needed)

- `BLOBHASH` opcode in the execution engine (works if blob hashes are provided)
- Point evaluation precompile at address `0x0a`
- KZG trusted setup (c-kzg library shipped with the client)
- `ParentBeaconBlockRoot` in payload attributes (set since Ecotone)

### What needs to change

The blob model requires changes at three layers of the OP Stack:

#### Layer 1: Execution engine (op-geth or op-reth) — client fork required

| Change | Description | Complexity |
|--------|-------------|------------|
| Remove blob tx rejection | Delete the `IsOptimism() && BlobTxType` check in txpool validation | One line, but it's a fork |
| Blob sidecar storage | Store blob sidecars for L2-originated blobs. On L1 this is the consensus client's job; on L2 the execution engine (or a sidecar service) must retain them | Medium |
| Blob sidecar RPC | Serve blob data via `eth_getBlobSidecars` or equivalent for the off-chain DB | Low — RPC endpoint addition |
| Blob gas pricing | Configure L2 blob gas base fee, target, and limit. Currently undefined for L2-originated blobs | Genesis/config |

#### Layer 2: Consensus/derivation (op-node) — may need changes

| Change | Description | Complexity |
|--------|-------------|------------|
| Engine API blob fields | Ensure ForkchoiceUpdate and NewPayload payloads include blob versioned hashes for L2 blocks containing user blobs. Currently this path only handles L1-derived blob hashes. | Medium — Engine API integration |
| Block building with blobs | The sequencer's block builder (op-node) must include type 3 transactions from the txpool and pass their blob hashes to the execution engine | Medium |

#### Layer 3: Infrastructure (no client changes)

| Change | Description | Complexity |
|--------|-------------|------------|
| Blob retention | Configure how long blob sidecars are stored. Default L1 semantics prune after ~18 days. | Config or sidecar service |
| Blob archival | The off-chain DB or a separate archiver fetches and stores blob data within the retention window | Application-level service |

### Blob retention strategy

Three options, increasing in complexity:

**Option A — Fixed retention window**: Keep all blobs for N days (e.g., 90 days). Simple, predictable storage costs. Entities living longer than N days require the off-chain DB to have cached the data within the window.

**Option B — Contract-aware retention**: A background process reads `EntityRegistry.entities(key).expiresAt` and prunes only after that block. Precise, but couples the sequencer to a specific contract.

**Option C — Client-responsibility model (recommended)**: The sequencer retains blobs for a fixed short window (e.g., 7 days). The off-chain DB is responsible for fetching and archiving blob data within that window. After the window, the sequencer doesn't have it, but the DB does. This is the simplest approach and matches how Ethereum L1 works — consumers of blob data are expected to fetch it before the pruning window.

### Throughput analysis

#### Constraints

Three factors limit blob throughput:

1. **KZG proof generation**: ~1ms per blob on modern hardware (single-threaded). Parallelizable across cores — a 16-core machine can generate 16 proofs concurrently.
2. **Block gas limit**: Each entity CREATE costs ~75K execution gas (storage + hashing), independent of blob size. At 60M block gas limit, that's ~800 entity operations per block.
3. **Blobs per block/transaction**: On L1, capped at 6 per tx and a target of 3 per block. On a dedicated L2 with a forked client, this is configurable. The practical limit is sequencer memory — each blob is 128KB, so 256 blobs = 32MB per block held in memory during building.

The binding constraint shifts depending on configuration:
- At low blob counts, **blob slots** are the bottleneck (each blob = one file chunk)
- At high blob counts, **execution gas** becomes the bottleneck (~75K gas per entity operation)
- At very high blob counts, **KZG computation time** and **sequencer memory** limit throughput

#### Blobs per transaction

The L1 EIP-4844 limit of 6 blobs per transaction is a protocol constant, not a cryptographic limit. On a dedicated L2 with a forked client, this can be raised. The practical upper bound per transaction is constrained by:
- Transaction propagation size (no peers on dedicated L2, so no p2p limit)
- Sequencer memory during block building
- Engine API payload size

Raising to 64 or 128 blobs per transaction is technically feasible on a dedicated L2.

#### Blobs per block

The L1 target of 3 blobs/block (max 6) exists to limit L1 bandwidth and state growth. On a dedicated L2:
- No bandwidth concern (single sequencer, no peer propagation)
- Blob data is ephemeral (pruned after entity expiry)
- The limit can be raised to whatever the sequencer hardware supports

#### Throughput scenarios

**Conservative (OP Stack defaults, minimal changes):**

| Parameter | Value |
|-----------|-------|
| Block time | 2s |
| Blobs per block | 6 |
| Block gas limit | 60M |
| Max entities per block | 6 (blob-limited, not gas-limited) |

| Metric | Value |
|--------|-------|
| Raw throughput | 384 KB/s (6 × 128KB / 2s) |
| Entity creates/sec | 3 |
| Time to upload 10MB | ~27s (79 blobs ÷ 3/s) |
| KZG overhead per block | 6ms (negligible) |

**Moderate (raised blob limit, 2s blocks):**

| Parameter | Value |
|-----------|-------|
| Block time | 2s |
| Blobs per block | 32 |
| Block gas limit | 60M |
| Max entities per block | 32 (blob-limited) |

| Metric | Value |
|--------|-------|
| Raw throughput | 2 MB/s |
| Entity creates/sec | 16 |
| Time to upload 10MB | ~5s |
| KZG overhead per block | 32ms (2% of block time) |

**Aggressive (high blob count, 1s blocks):**

| Parameter | Value |
|-----------|-------|
| Block time | 1s |
| Blobs per block | 128 |
| Block gas limit | 120M |
| Max entities per block | 128 (blob-limited) |

| Metric | Value |
|--------|-------|
| Raw throughput | 16 MB/s |
| Entity creates/sec | 128 |
| Time to upload 10MB | <1s |
| Time to upload 100MB | ~5s |
| KZG overhead per block | 128ms (13% of block time, parallelizable to ~8ms on 16 cores) |
| Sequencer memory per block | 16 MB blob data |

**Maximum theoretical (pushing hardware limits):**

| Parameter | Value |
|-----------|-------|
| Block time | 1s |
| Blobs per block | 512 |
| Block gas limit | 250M |
| Max entities per block | 512 (blob-limited) or ~3,333 (gas-limited) |

| Metric | Value |
|--------|-------|
| Raw throughput | 64 MB/s |
| Entity creates/sec | 512 |
| Time to upload 100MB | ~1.5s |
| Time to upload 1GB | ~16s |
| KZG overhead per block | 512ms (parallelized to ~32ms on 16 cores) |
| Sequencer memory per block | 64 MB blob data |

At this level, the bottleneck shifts to disk I/O for blob storage and network I/O for RPC serving.

#### Comparison with calldata model

For a 10MB file upload:

| Model | Config | Time | Cost (OP L2) | Txs required |
|-------|--------|------|-------------|--------------|
| Calldata | 60M gas, 128KB tx, 2s blocks | ~28s | ~$103 | 79 |
| Blob (conservative) | 6 blobs/block, 2s | ~27s | ~$0.08 | 14 |
| Blob (moderate) | 32 blobs/block, 2s | ~5s | ~$0.08 | 3 |
| Blob (aggressive) | 128 blobs/block, 1s | <1s | ~$0.08 | 1 |

The cost is the same across blob configurations — blob fees are per-blob regardless of how many fit in a block. The difference is wall-clock time. The aggressive config matches commodity upload speeds.

#### Storage growth

At sustained maximum throughput (64 MB/s), the sequencer accumulates:
- 5.5 TB/day of blob data
- With a 7-day retention window: ~38 TB storage
- With a 30-day retention window: ~166 TB storage

This is within the range of a single NVMe array, but requires planning. The moderate config (2 MB/s) is more practical for sustained operation: 173 GB/day, 1.2 TB for 7-day retention.

### L2 peering constraints

On a single-sequencer L2, the sequencer produces blocks and propagates them to verifier (non-sequencing) nodes via L2 p2p gossip. Blob data adds a new dimension to this propagation.

#### How L2 block propagation works today

The sequencer gossips **unsafe blocks** to L2 peers via the OP Stack's p2p network. These are execution payloads (block headers + transaction list), not full blob sidecars. Verifier nodes receive the payload, execute it locally, and advance their state.

With blob transactions, the propagation question is: **do verifier nodes need the blob data?**

#### Verifier nodes don't need blob data for state advancement

The execution engine only needs the blob **versioned hashes** (from the Engine API payload), not the blob bytes. `blobhash(n)` is populated from the payload attributes, not from locally stored blob data. So:

- The sequencer gossips the block payload (including blob versioned hashes)
- Verifier nodes execute the block — `blobhash()` works because the hashes are in the payload
- The contract stores the blobHash in coreHash
- **No blob data transfer required for state consensus**

This means blob data does not constrain L2 p2p propagation at all for state advancement.

#### Verifier nodes DO need blob data for data availability

If a verifier node wants to serve blob data (for the off-chain DB, for user queries, or for independent verification), it needs the actual blob bytes. This is a **separate data channel** from block propagation:

| Propagation channel | What flows | Size per block | Required for consensus? |
|---|---|---|---|
| Block gossip (existing) | Execution payload + blob versioned hashes | ~1-10 KB per block (same as today) | Yes |
| Blob data (new) | Blob sidecars | Up to 128KB × blobs_per_block | No — only for data serving |

#### Peering impact at different throughput levels

| Config | Blob data per block | Block gossip (unchanged) | Blob gossip (new) | Network impact |
|---|---|---|---|---|
| Conservative (6 blobs) | 768 KB | ~5 KB | 768 KB/2s = 384 KB/s | Negligible — comparable to a video stream |
| Moderate (32 blobs) | 4 MB | ~5 KB | 4 MB/2s = 2 MB/s | Low — standard broadband |
| Aggressive (128 blobs) | 16 MB | ~5 KB | 16 MB/1s = 16 MB/s | Moderate — requires dedicated bandwidth between nodes |
| Maximum (512 blobs) | 64 MB | ~5 KB | 64 MB/1s = 64 MB/s | High — datacenter-grade networking between nodes |

#### Key insight

Blob data propagation is **optional for consensus** but **required for data availability**. You can run a lean verifier network that only gossips block headers (no blob data), with a separate archival/DA tier that fetches blob data directly from the sequencer. This separates the consensus network (light, fast) from the data availability network (heavy, can tolerate latency).

For a dedicated L2 where you control all nodes, the practical architecture is:
- 1 sequencer producing blocks + storing blobs
- 1-3 verifier nodes for consensus redundancy (no blob data needed)
- 1 archival node or off-chain DB fetching blobs from the sequencer via RPC

The verifier nodes add no blob bandwidth. The archival node's bandwidth scales with throughput but only needs a single RPC connection to the sequencer, not p2p gossip.

### KZG commitments in fault proofs

On an OP Stack L2, the fault proof game is how L1 verifies that the sequencer posted correct state roots. The question: can KZG commitments from L2 blob transactions be verified during a fault proof?

#### How OP Stack fault proofs work today

1. Sequencer posts L2 state roots to L1 (via op-proposer)
2. A challenger can dispute a state root by initiating a fault proof game on L1
3. The game bisects the disputed execution trace down to a single instruction
4. The single instruction is executed on L1 (via the MIPS/RISC-V onchain VM) to determine correctness
5. The game resolves: either the state root is valid or the challenger wins

The fault proof only needs to re-execute the disputed instruction with the correct inputs. It doesn't re-execute the entire block.

#### Can `blobhash()` be proven in a fault proof?

**Yes, in principle.** The `blobhash()` opcode is deterministic given the block's blob versioned hashes. During a fault proof:

1. The disputed block's blob versioned hashes are part of the block header (or Engine API payload)
2. These hashes were committed to when the sequencer posted the state root to L1
3. The fault proof VM can be provided with the correct blob versioned hashes as witness data
4. `blobhash(n)` in the onchain VM returns the nth hash from this witness data
5. The contract execution (EntityRegistry storing blobHash in coreHash) is deterministically re-executed

The blob **data** is not needed for the fault proof — only the blob **versioned hashes**, which are part of the block metadata committed to L1.

#### What needs to be true

For fault proofs to work with L2 blob transactions:

| Requirement | Status |
|---|---|
| Blob versioned hashes included in L2 block metadata | Needs implementation — currently L2 blocks don't carry blob metadata for user-originated blobs |
| Block metadata committed to L1 via state root | Already works — the state root covers all execution results |
| Fault proof VM supports `blobhash()` opcode | Needs verification — the MIPS/RISC-V fault proof VM must handle this opcode |
| Blob data available for dispute window | The blob versioned hashes (not data) must be available. Since they're derived from block metadata committed to L1, they are. |

#### Point evaluation precompile in fault proofs

If the contract used the point evaluation precompile (`0x0a`) to verify blob contents, the fault proof would need to re-execute that precompile call. This requires:
- The precompile inputs (commitment, point, claimed value, proof) as witness data
- The fault proof VM to implement KZG verification

The current OP Stack fault proof VM (op-program) already handles precompile calls for L1-derived blobs during derivation. Extending this to L2-originated blobs is a matter of providing the correct witness data, not new cryptography.

#### Alternative: prove KZG commitments via L1 directly

A simpler approach that avoids fault proof complexity:

1. When the sequencer creates an entity with a blob, it also posts the KZG commitment to L1 (48 bytes, cheap)
2. Anyone can verify the L1-posted commitment against the L2 state root
3. If they don't match, the sequencer is provably dishonest
4. This is a **validity proof** (one check proves correctness) rather than a **fault proof** (interactive game)

This bypasses the fault proof game entirely for blob commitment verification. The cost is 48 bytes of L1 calldata per entity — roughly $0.002 at current L1 gas prices. For high-value entities this may be worth the direct L1 guarantee.

### Experimental: DA-gated execution with on-chain DAC

A stronger approach that eliminates the withholding problem at the protocol level. Instead of executing entity operations immediately and hoping the data is available, the EntityRegistry uses **two-stage execution** where the changeSetHash only advances after a configurable quorum of Data Availability Committee (DAC) members confirm they have verified and stored the blob data.

#### Two-stage execution model

**Stage 1 — Propose**: The sequencer includes the blob transaction. The contract verifies the KZG commitment via `blobhash()` and stores the entity as **pending**. The changeSetHash does not advance.

```
execute(Op) → pendingEntity stored
           → blob verified via blobhash()
           → emits EntityProposed(entityKey, blobHash)
           → changeSetHash unchanged
```

**Stage 2 — Confirm**: DAC members independently fetch the blob data from the sequencer, verify the KZG commitment, and sign attestations. Once quorum is reached, anyone can submit the aggregated attestations. The entity finalizes and the changeSetHash advances.

```
confirmEntity(entityKey, signatures[]) → quorum verified
           → entity moves pending → active
           → changeSetHash advances
           → emits EntityCreated(entityKey, blobHash, entityHash)
```

If quorum is not reached within a timeout (configurable, e.g., 100 blocks), the pending entity can be cancelled and discarded.

#### Entity lifecycle with DAC

| Phase | Actor | What happens | changeSetHash |
|---|---|---|---|
| Propose | Sequencer | Blob verified, entity pending, coreHash computed | Unchanged |
| Attest | DAC members (off-chain) | Each fetches blob, verifies KZG, signs attestation | Unchanged |
| Confirm | Anyone | Aggregated signatures submitted, quorum checked | Advances |
| Active | — | Entity queryable, blob data guaranteed available from DAC | — |
| Expire | Anyone | Entity past expiresAt, removable | Advances |

#### DAC contract sketch

```solidity
uint256 public quorum;                                      // e.g., 2 of 3
mapping(address => bool) public committee;                   // registered DAC members
mapping(bytes32 => PendingEntity) public pending;            // entityKey → pending state
mapping(bytes32 => mapping(address => bool)) public attested; // entityKey → member → attested
mapping(bytes32 => uint256) public attestCount;              // entityKey → count
```

The quorum is configurable: 1-of-1 for a trusted archiver, 2-of-3 for redundancy, 5-of-7 for high assurance. DAC membership can be governed (multisig, governance contract, etc.).

#### Off-chain DB sync model

The DB only tracks confirmed entities. Pending entities are invisible to the changeSetHash:

```
EntityProposed  →  DB ignores (not finalized, data not guaranteed)
EntityCreated   →  DB indexes (DAC confirmed, data guaranteed available)
```

The DB has a **protocol-level guarantee** that any entity in its changeSetHash has blob data available from at least `quorum` DAC members. The "commitment exists, data missing" failure mode is eliminated.

#### Latency

The two-stage model adds finality latency:

| Step | Time | Notes |
|---|---|---|
| Propose tx mined | 1 block (2s) | — |
| DAC fetches blob + verifies KZG | ~2-5s | Network + computation |
| Confirm tx mined (aggregated sigs) | 1 block (2s) | BLS aggregation off-chain |
| **Total** | **~4-9s** | Comparable to S3 eventual consistency |

With off-chain BLS signature aggregation, DAC members don't each submit separate transactions. A single aggregator collects signatures and submits one confirm transaction.

#### Trust model

| Actor | Can do | Can't do | Penalty |
|---|---|---|---|
| Sequencer | Propose entities | Finalize without DAC quorum | Pending entity times out |
| DAC member | Attest to data availability | Attest without actually having data (if challenged) | Bond slashed |
| DAC quorum | Confirm entity finalization | Be bypassed — changeSetHash won't advance without quorum | — |
| Colluding sequencer + DAC minority | Nothing — quorum not reached | — | Pending entity times out |

The key property: **no entity can enter the changeSetHash without `quorum` independent parties confirming they have the data.** This is a stronger guarantee than any external DA layer provides, because the DA attestation is atomic with the execution state.

#### Trade-offs

- **Liveness depends on DAC**: If fewer than `quorum` members are online, no entities can finalize. Mitigated by choosing quorum < committee size (e.g., 2-of-3).
- **Throughput bounded by slowest DAC member**: All members must verify before quorum is reached. Mitigated by allowing fast members to attest while slow members catch up.
- **Complexity**: Two-phase commit adds contract complexity and a new confirmation transaction type. The EntityRegistry becomes a stateful workflow engine rather than a simple registry.
- **Gas overhead**: Each entity pays gas for both the propose and confirm transactions. At ~75K gas each, this roughly doubles the execution cost per entity. On a dedicated L2 with near-zero gas prices, this is negligible.

#### Why this is novel

Most DA solutions (Celestia, EigenDA, OP Stack alt-DA) treat data availability as an external property that the rollup assumes. This design **integrates DA confirmation into the smart contract execution model** — the changeSetHash is the authority, and it refuses to advance without DA quorum. The execution state and the DA attestation are atomic.

### Summary of effort

The smart contract change is straightforward (~50 lines modified). The sequencer change is a **client fork** — removing one line from op-geth's txpool validation opens the door, but properly supporting L2 blob sidecars (storage, RPC serving, Engine API integration) is a medium-complexity effort across the execution engine and op-node. This is not a configuration change; it is new functionality that the OP Stack does not currently provide.

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
