# Payload Commitment Analysis

## TL;DR

Payload calldata is 96% of the gas cost for entity operations. This document
proposes removing payload bytes from calldata entirely and replacing them
with cryptographic commitments (32 bytes each) that the sequencer's storage
layer backs.

**Contract changes**: `bytes payload` in the Operation struct becomes
`bytes32[] payloadCommitments` — an array of per-blob KZG commitments
(one per 128 KiB chunk). The commitment array is hashed into `coreHash`
via EIP-712 array encoding. A ~127 KB CREATE drops from 2.1M gas to ~39k
gas (54x reduction; 135x under EIP-7623 floor pricing).

**Transaction format**: A new transaction type separates calldata (operation
metadata the EVM executes) from a payload sidecar (raw bytes the sequencer
stores). The contract introspects sidecar metadata via `BLOBHASH`,
`BLOBSIZE`, and `BLOBCOUNT` opcodes — enough to verify commitments and
enforce storage limits without touching the payload bytes.

**Storage economics**: An admin-controlled storage cap sets the upper bound
on total outstanding byte-blocks. A backpressure pricing curve (EIP-1559-
style exponential) increases storage fees as utilization approaches the cap.
Gas fees (EIP-1559 basefee) and storage fees are independent dimensions —
storage cost is per-operation, not per-transaction, so batching decisions
are driven by atomicity needs rather than cost gaming.

**Sequencer pipeline**: A write-ahead pattern gates block finality on
confirmed storage writes. Payloads are staged in the storage backend
(pebble, postgres, rocksdb, or any store with atomic batch semantics)
before EVM execution; the block is only sealed after the storage commit
succeeds. If storage fails, the block is discarded and transactions are
re-queued.

**Syncing and verification**: Other nodes fetch payloads from the
sequencer's API and verify them against on-chain commitments. The
commitment is the contract between the sequencer and every consumer —
any mismatch is provable. State roots and changeset hashes settle to L1.

---

## Problem Statement

In the current EntityRegistry design, payload bytes are passed as calldata to
`execute()` and hashed inline via `keccak256(payload)` to produce `coreHash`.
The payload is never written to contract storage — it exists only in calldata
and event logs for off-chain indexing.

The issue: **calldata cost dominates everything else**.

Measured calldata breakdown for a single CREATE with a ~127 KB payload
(`application/json`, 3 attributes):

```
Calldata breakdown (single CREATE, ~127 KB payload):
╭──────────────────────┬──────────┬────────────────┬─────────────╮
│ Section              │ Bytes    │ Gas (Standard) │ Gas (Floor) │
├──────────────────────┼──────────┼────────────────┼─────────────┤
│ Selector             │        4 │             64 │         160 │
│ ABI framing          │      224 │          1,160 │       2,900 │
│ Operation fields     │      256 │          1,276 │       3,190 │
│ Attributes (3×192B)  │      576 │          3,228 │       8,070 │
│ Payload              │  129,888 │      2,077,836 │   5,194,590 │
├──────────────────────┼──────────┼────────────────┼─────────────┤
│ Total calldata       │  130,948 │      2,083,564 │   5,229,910 │
│ + Intrinsic (21,000) │          │      2,104,564 │   5,250,910 │
╰──────────────────────┴──────────┴────────────────┴─────────────╯

Payload share: 129,888 of 130,948 bytes (99.2%)
Payload gas:   2,077,836 of 2,083,564 (99.7% of standard calldata gas)
```

The payload is 99.2% of the calldata bytes and 99.7% of the calldata gas.
Everything else — selector, ABI framing, operation fields, three full
attributes — totals 1,060 bytes and 5,728 gas. The payload alone is
2,077,836 gas at standard rates.

Under EIP-7623 floor pricing (48 gas/non-zero byte for data-heavy
transactions), the same CREATE costs **5.25M gas** — 2.5x the standard
rate, with the payload accounting for 5.19M of that.

---

## Proposal: Commitment-Based Payload Storage

Replace on-chain payload calldata with an off-chain payload commitment. The
sequencer (as the sole block producer in the application-specific chain)
witnesses the payload data, computes a cryptographic commitment, and makes
that commitment available to the contract. The contract hashes the commitment
into `coreHash` and `entityHash`, preserving the integrity chain.

```
Current flow:
  Client → execute([...payload bytes...]) → keccak256(payload) → coreHash

Proposed flow:
  Client → submit payload to sequencer → sequencer computes commitment
  Client → execute([...commitment only...]) → commitment → coreHash
  Sequencer → stores payload on disk, maintains witness proof
```

The contract never sees the raw payload. It receives a fixed-size commitment
(32–48 bytes) that cryptographically binds the entity to the exact payload
data the sequencer witnessed.

---

## Commitment Scheme Options

### Option A: KZG Polynomial Commitment (Blob-Style)

The sequencer treats each payload as a polynomial over the BLS12-381 scalar
field and computes a KZG commitment. This mirrors EIP-4844's blob handling.

**How it works:**

1. Client submits payload to sequencer as a sidecar (not in the transaction).
2. Sequencer encodes payload as a polynomial of up to 4096 field elements
   (128 KiB per blob). Larger payloads span multiple blobs.
3. Sequencer computes `commitment = KZG_COMMIT(polynomial, SRS)` — a 48-byte
   G1 point on BLS12-381.
4. Sequencer derives `versioned_hash = 0x01 || SHA256(commitment)[1:]` — a
   32-byte value compatible with EIP-4844's `BLOBHASH` opcode.
5. The contract receives `versioned_hash` (via a sequencer-provided opcode or
   precompile, analogous to `BLOBHASH`) and hashes it into `coreHash`.
6. Sequencer stores the raw payload and the KZG proof on disk for the
   entity's TTL.

**On-chain cost (same ~127 KB CREATE, payload moved to sidecar):**

```
With commitment approach:
  Calldata (op metadata + ABI):       ~5,728 gas   (selector, fields, 3 attrs)
  Calldata (1 blob commitment):         ~512 gas   (32 bytes non-zero)
  SSTORE (commitment):               ~22,000 gas
  Hashing (keccak256):                   ~600 gas
  Execution overhead:                 ~10,000 gas
                                     ──────────
  Total:                              ~38,840 gas

  vs. current:                     2,104,564 gas   (54x reduction)
  vs. current (EIP-7623 floor):    5,250,910 gas   (135x reduction)
```

**Verification:** A challenger can invoke the point evaluation precompile
(50,000 gas) to verify that a specific data element is consistent with the
committed polynomial. This proves the sequencer's stored data matches the
on-chain commitment without revealing the full payload.

**Proof characteristics:**

| Property         | Value                                     |
|------------------|-------------------------------------------|
| Commitment size  | 48 bytes (G1 point) → 32 bytes versioned hash |
| Proof size       | 48 bytes (constant, regardless of payload size) |
| Prover time      | ~42ms per 128 KiB blob                    |
| Verifier time    | ~2ms (2 pairings)                         |
| On-chain verify  | 50,000 gas (point evaluation precompile)  |
| Trusted setup    | Required (Ethereum's ceremony: 141k+ contributors) |
| Post-quantum     | No                                        |
| Erasure coding   | Native (homomorphic property)             |

**Trade-offs:**

- (+) Constant proof size regardless of payload — ideal for large payloads
- (+) Native Ethereum support — `BLOBHASH` opcode, point evaluation precompile
- (+) Homomorphic — supports data availability sampling (DAS)
- (+) Well-audited — powers all EIP-4844 blob transactions today
- (-) Requires trusted setup (mitigated by Ethereum's ceremony)
- (-) Not post-quantum secure
- (-) Payload capped at 128 KiB per blob (multiple blobs for larger payloads)
- (-) Sequencer must run BLS12-381 cryptography (c-kzg-4844 library)

### Option B: Merkle Root Commitment (Hash-Based)

The sequencer splits the payload into fixed-size chunks, builds a Merkle tree,
and provides the root as the commitment.

**How it works:**

1. Client submits payload to sequencer.
2. Sequencer chunks payload into 32-byte leaves (or a configurable chunk size).
3. Sequencer builds a binary Merkle tree and computes the root.
4. The contract receives the 32-byte Merkle root and hashes it into `coreHash`.
5. For verification, the sequencer provides Merkle inclusion proofs for
   individual chunks.

**Proof characteristics:**

| Property         | Value                                     |
|------------------|-------------------------------------------|
| Commitment size  | 32 bytes (Merkle root)                    |
| Proof size       | O(log n) — ~384 bytes for 4096 chunks     |
| Prover time      | O(n) hashes — fast for typical payloads   |
| Verifier time    | O(log n) hashes                           |
| On-chain verify  | ~5,000–15,000 gas (log n keccak256 ops)   |
| Trusted setup    | None                                      |
| Post-quantum     | Yes (hash-function security only)         |
| Erasure coding   | Not natively supported                    |

**Trade-offs:**

- (+) No trusted setup — hash function only
- (+) Post-quantum secure
- (+) Simplest implementation — standard library in every language
- (+) Cheapest on-chain verification for small proofs
- (+) Well-understood, battle-tested pattern
- (-) Proof size grows with payload size (logarithmic)
- (-) No homomorphic property — no DAS, no proof aggregation
- (-) Proving erasure-coding correctness requires additional machinery
- (-) Less standard in Ethereum's DA ecosystem (Ethereum chose KZG)

### Option C: FRI-Based Commitment (STARK-Friendly)

The sequencer encodes the payload as Reed-Solomon evaluations, commits via
Merkle tree, and produces a FRI proximity proof.

**Proof characteristics:**

| Property         | Value                                     |
|------------------|-------------------------------------------|
| Commitment size  | 32 bytes (Merkle root of RS evaluations)  |
| Proof size       | O(log^2 n) — typically 10s of KB          |
| Prover time      | O(n log n)                                |
| Verifier time    | O(log^2 n) hashes                         |
| Trusted setup    | None                                      |
| Post-quantum     | Yes                                       |
| Erasure coding   | Native (FRI is a Reed-Solomon proof)      |

**Trade-offs:**

- (+) No trusted setup, post-quantum secure
- (+) Natively proves data is a valid RS codeword — ideal for DAS
- (+) Aligned with STARK ecosystem (potential ZK proof composition later)
- (-) Larger proofs than KZG or Merkle (~10–50 KB)
- (-) Higher prover complexity
- (-) No Ethereum-native precompile support
- (-) Less mature tooling for data availability specifically

### Recommendation

For the initial implementation: **Option A (KZG)** as the primary scheme,
with **Option B (Merkle)** as a fallback or for environments without
BLS12-381 support.

Rationale:

1. The sequencer is an application-specific chain targeting Ethereum
   settlement. KZG is the Ethereum-native commitment scheme with precompile
   support already deployed.

2. The payload sizes (up to 128 KiB per blob) align naturally with
   EIP-4844's blob structure. For payloads larger than 128 KiB, multiple
   commitments can be chained or aggregated.

3. The constant 48-byte proof size means verification cost is independent
   of payload size — a sequencer storing 1 KB and 100 KB payloads has the
   same proof overhead.

4. KZG's homomorphic property provides a natural path to DAS if the
   sequencer network grows beyond a single node.

5. Ethereum's trusted setup ceremony (141,000+ participants) is a public
   good that the sequencer inherits for free.

---

## Contract Changes

### CoreHash Typehash

The `coreHash` EIP-712 type string changes to replace `bytes payload` with
a commitment array:

```
Current:
  CoreHash(
    bytes32    entityKey,
    address    creator,
    uint32     createdAt,
    bytes32[4] contentType,
    bytes      payload,              ← dynamic, hashed as keccak256(payload)
    bytes32    attributesHash
  )

Proposed:
  CoreHash(
    bytes32    entityKey,
    address    creator,
    uint32     createdAt,
    bytes32[4] contentType,
    bytes32[]  payloadCommitments,   ← array of per-blob commitments
    bytes32    attributesHash
  )
```

Per EIP-712 encoding rules, `bytes32[]` is encoded as
`keccak256(abi.encodePacked(elements))` — the keccak256 of the concatenated
array members. This produces a single 32-byte value in the ABI encoding,
same as `keccak256(payload)` did before. The typehash string changes, so
all existing entity hashes are invalidated (this is a breaking change to
the encoding scheme, not a migration).

For a single-blob payload, the encoding is:
`keccak256(abi.encodePacked(commitment_0))` = `commitment_0` itself (a
single 32-byte element). For multi-blob:
`keccak256(abi.encodePacked(commitment_0, commitment_1, ..., commitment_n))`.

### Entity.coreHash()

```solidity
// Current signature:
function coreHash(
    bytes32 key,
    address creator,
    BlockNumber createdAt,
    Mime128 calldata contentType,
    bytes calldata payload,              // ← full payload bytes
    Attribute[] calldata attributes
) internal pure returns (bytes32)

// Proposed signature:
function coreHash(
    bytes32 key,
    address creator,
    BlockNumber createdAt,
    Mime128 calldata contentType,
    bytes32[] calldata payloadCommitments, // ← per-blob commitment array
    Attribute[] calldata attributes
) internal pure returns (bytes32)
```

The function body changes from `keccak256(payload)` to EIP-712 array
encoding of the commitments:

```solidity
// Current:
keccak256(payload)

// Proposed:
keccak256(abi.encodePacked(payloadCommitments))
// Commits to the exact sequence and content of all blobs
```

### Operation Struct

```solidity
// Current:
struct Operation {
    uint8 operationType;
    bytes32 entityKey;
    bytes payload;           // ← dynamic bytes, unbounded
    Mime128 contentType;
    Attribute[] attributes;
    BlockNumber expiresAt;
    address newOwner;
}

// Proposed:
struct Operation {
    uint8 operationType;
    bytes32 entityKey;
    bytes32[] payloadCommitments;  // ← array of 32-byte blob commitments
    Mime128 contentType;
    Attribute[] attributes;
    BlockNumber expiresAt;
    address newOwner;
}
```

A single payload may span multiple 128 KiB blobs. Rather than a single
commitment over the entire payload (which would require a custom aggregation
scheme), each blob gets its own KZG commitment and the contract receives the
array. This keeps each commitment aligned with the standard 128 KiB blob
structure and avoids inventing a new commitment format for large payloads.

The `payloadCommitments` array is empty for EXTEND, TRANSFER, DELETE, EXPIRE.
For CREATE/UPDATE, it contains one entry per 128 KiB blob (or partial final
blob) that makes up the payload.

### Multi-Blob Chunking

A payload larger than 128 KiB is split into sequential blobs at the sidecar
level. Each blob is independently committed:

```
Payload: 350 KiB

  blob 0:  bytes[0..128K)     → commitment_0  (full 128 KiB)
  blob 1:  bytes[128K..256K)  → commitment_1  (full 128 KiB)
  blob 2:  bytes[256K..350K)  → commitment_2  (94 KiB, zero-padded to field elements)

Operation.payloadCommitments = [commitment_0, commitment_1, commitment_2]
```

Small payloads (<=128 KiB) produce a single-element array. The contract
doesn't need to know the blob size — it just hashes the commitment array
into `coreHash`. The sequencer handles the chunking and reassembly.

### Commitment Generation Cost

KZG commitment generation is the sequencer's prover cost — it runs once per
blob when the transaction is included. The contract never performs this
computation.

| Payload size | Blobs | Sequential (c-kzg/BLST) | Parallelized (est. 8 cores) |
|--------------|-------|-------------------------|----------------------------|
| 64 KiB       | 1     | ~42ms                   | ~42ms                      |
| 128 KiB      | 1     | ~42ms                   | ~42ms                      |
| 512 KiB      | 4     | ~168ms                  | ~50ms                      |
| 1 MiB        | 8     | ~336ms                  | ~85ms                      |
| 10 MiB       | 80    | ~3.4s                   | ~430ms                     |

Benchmarks: c-kzg-4844 / BLST on AMD Ryzen 9 5950X. Batch verification of
64 blobs across 16 cores takes ~18ms total (~0.28ms/blob effective),
demonstrating near-linear parallelism.

The commitment is the bottleneck only for very large payloads (10+ MiB) on
a single core. With even modest parallelism, the sequencer can commit
hundreds of megabytes per second. Disk I/O and network ingress are more
likely bottlenecks in practice.

### Hashing the Commitment Array into coreHash

The commitment array replaces `keccak256(payload)` in the EIP-712 encoding.
The array is hashed per EIP-712 array rules — `keccak256` of the
concatenated elements:

```solidity
// In Entity.coreHash():

// Current:
keccak256(payload)

// Proposed:
keccak256(abi.encodePacked(payloadCommitments))
// i.e. keccak256(commitment_0 || commitment_1 || ... || commitment_n)
```

This produces a single `bytes32` that commits to the exact sequence of
blobs. Reordering, omitting, or substituting any blob changes the hash.
The encoding is deterministic and cheap — just a keccak256 over
`n * 32 bytes`.

### Transaction Type: Decoupling Calldata from Payload Data

A single `execute()` call can batch multiple CREATE and UPDATE operations,
each carrying its own payload. With the current design, all payloads are
packed into calldata — one large blob of bytes. The proposal requires a
clean separation between the two data planes:

- **Calldata**: Operation metadata the EVM executes against (commitments,
  entity keys, attributes, content types). Small, fixed-size per operation.
- **Payload sidecar**: Raw payload bytes the sequencer stores. Arbitrary
  size, never enters the EVM. Indexed positionally — payload 0 corresponds
  to the first operation that needs one, payload 1 to the second, etc.

This mirrors EIP-4844's type-3 transaction structure, where blob data travels
alongside but separate from the transaction's calldata. The key difference:
in the Arkiv sequencer, the sidecar protocol is application-defined, not a
consensus-level transaction type.

```
Type-3 transaction (EIP-4844 analogy):

  ┌───────────────────────────────────────────────────────────────┐
  │ Transaction envelope                                          │
  │                                                               │
  │  calldata: execute([                                          │
  │    { CREATE, payloadCommitments: [0xa, 0xb, 0xc], ... }      │  ← op 0: 3 blobs
  │    { EXTEND, entityKey: 0xdef..., ... }                       │  ← op 1: no payload
  │    { CREATE, payloadCommitments: [0xd], ... }                 │  ← op 2: 1 blob
  │  ])                                                           │
  │                                                               │
  │  sidecar: [                                                   │
  │    blob_0: <128 KiB, op 0 chunk 0>,                           │
  │    blob_1: <128 KiB, op 0 chunk 1>,                           │
  │    blob_2: <94 KiB padded, op 0 chunk 2>,                     │
  │    blob_3: <50 KiB padded, op 2 chunk 0>,                     │
  │  ]                                                            │
  └───────────────────────────────────────────────────────────────┘
```

The sidecar is a flat array of blobs, ordered sequentially across
payload-bearing operations. Op 0 declares 3 commitments and consumes
sidecar blobs 0–2. Op 2 declares 1 commitment and consumes sidecar blob 3.
The contract doesn't need to know sidecar indices — it receives the
commitment array per operation and hashes it into `coreHash`. The sequencer
validates that each commitment matches its corresponding sidecar blob before
block inclusion.

The total blob count for the transaction is the sum of all
`payloadCommitments.length` across payload-bearing operations. The sequencer
enforces per-tx blob limits at the mempool level.

### Payload Introspection Opcodes

With multi-blob payloads, the contract needs to verify commitments and
enforce storage limits across all blobs in an operation. The sidecar is a
flat array of blobs — the contract addresses them by global index.

**Design: three opcodes**

```
BLOBHASH(index)  → bytes32   commitment at sidecar blob index (or zero)
BLOBSIZE(index)  → uint256   byte length of blob at index (or zero)
BLOBCOUNT()      → uint256   total number of blobs in this transaction
```

These follow the existing `BLOBHASH` precedent from EIP-4844. `BLOBSIZE`
and `BLOBCOUNT` are additions that let the contract do accounting without
the sequencer having to pass sizes in calldata.

Gas cost: 3 gas each (same as `BLOBHASH` — reads from tx execution context,
no crypto).

**What this enables in the contract:**

```solidity
function _create(Operation calldata op, BlockNumber current, uint256 blobStart)
    internal returns (bytes32 key, bytes32 entityHash_, uint256 blobEnd)
{
    uint256 blobCount = op.payloadCommitments.length;
    if (blobCount == 0) revert EmptyPayload();

    // Validate each blob commitment against the sidecar
    uint256 totalBytes = 0;
    for (uint256 i = 0; i < blobCount; i++) {
        uint256 idx = blobStart + i;
        require(blobhash(idx) == op.payloadCommitments[i], "commitment mismatch");
        totalBytes += blobsize(idx);
    }

    // Contract-enforced storage limits
    require(totalBytes <= MAX_PAYLOAD_SIZE, "payload too large");

    // Storage accounting — charge proportional to actual data
    _accountStorage(msg.sender, totalBytes, op.expiresAt);

    // ... hash op.payloadCommitments into coreHash
    blobEnd = blobStart + blobCount;
}
```

The `blobStart` offset is tracked as the contract iterates through
operations, advancing by each operation's blob count:

```solidity
uint256 blobOffset = 0;
for (uint32 opSeq = 0; opSeq < ops.length; opSeq++) {
    if (ops[opSeq].operationType == Entity.CREATE) {
        (, , blobOffset) = _create(ops[opSeq], current, blobOffset);
    } else if (ops[opSeq].operationType == Entity.UPDATE) {
        (, , blobOffset) = _update(ops[opSeq], current, blobOffset);
    } else {
        require(ops[opSeq].payloadCommitments.length == 0);
        _dispatch(ops[opSeq], current);
    }
}
// Final check: all sidecar blobs consumed
require(blobOffset == blobcount(), "unconsumed blobs");
```

The trailing `blobcount()` check ensures the sidecar contains exactly the
blobs the operations reference — no extra blobs smuggled in, no blobs left
unaccounted for.

**Optional: `PAYLOAD_INFO` precompile (richer metadata)**

If storage pricing needs non-zero byte granularity, a precompile can
return more metadata per blob:

```
Address:  0x0B (or sequencer-assigned precompile slot)
Gas cost: 100
Input:    32 bytes — uint256 blob index
Output:   96 bytes:
            [0:32]  bytes32   commitment     (versioned hash)
            [32:64] uint256   totalBytes     (blob length in bytes)
            [64:96] uint256   nonZeroBytes   (count of non-zero bytes)
```

This enables weighted storage pricing (dense data costs more) per the
storage accounting model described below. Add only if the simpler opcode
model proves insufficient.

### Sidecar Blob Indexing

The sidecar is a flat array of blobs. Each payload-bearing operation
consumes a contiguous slice of that array, sized by its
`payloadCommitments.length`. The contract tracks a running `blobOffset`
as it iterates through operations.

```
Sidecar blob layout for a batch:

  ops:     [CREATE_0 (3 blobs),  EXTEND_1 (0 blobs),  CREATE_2 (1 blob)]
  sidecar: [blob_0, blob_1, blob_2,                    blob_3          ]
            ╰─── CREATE_0 ───╯                          ╰ CREATE_2 ╯

  blobOffset after op 0: 3
  blobOffset after op 1: 3 (no blobs consumed)
  blobOffset after op 2: 4
  blobcount() == 4 ✓
```

No explicit index field needed in the Operation struct — the offset is
deterministic from the operation ordering and each operation's commitment
array length.

### Commitment Validation Flow

End-to-end, for a batch with a 350 KiB CREATE, an EXTEND, and a 50 KiB
CREATE:

```
Client submits:
  calldata:  execute([
    CREATE_0: { payloadCommitments: [0xa, 0xb, 0xc], ... }   ← 3 blobs (350 KiB)
    EXTEND_1: { payloadCommitments: [], ... }                  ← no payload
    CREATE_2: { payloadCommitments: [0xd], ... }               ← 1 blob (50 KiB)
  ])
  sidecar: [blob_0 (128K), blob_1 (128K), blob_2 (94K), blob_3 (50K)]

Sequencer pre-validation:
  1. Total declared blobs: 3 + 0 + 1 = 4
  2. Assert sidecar.length == 4
  3. For each blob: compute KZG commitment, assert matches declared commitment
  4. Reject on any mismatch

Contract execution:
  blobOffset = 0

  op 0 (CREATE_0, 3 blobs):
    for i in 0..3:
      assert blobhash(blobOffset + i) == op.payloadCommitments[i]
      totalBytes += blobsize(blobOffset + i)
    hash payloadCommitments into coreHash
    blobOffset += 3  → now 3

  op 1 (EXTEND_1, 0 blobs):
    assert op.payloadCommitments.length == 0
    no sidecar interaction
    blobOffset unchanged → still 3

  op 2 (CREATE_2, 1 blob):
    assert blobhash(3) == op.payloadCommitments[0]
    totalBytes += blobsize(3)
    hash payloadCommitments into coreHash
    blobOffset += 1  → now 4

  assert blobOffset == blobcount()  → 4 == 4 ✓

Sequencer post-execution:
  Store payload for CREATE_0 (reassembled from blobs 0-2) → storage backend
  Store payload for CREATE_2 (blob 3) → storage backend
```

---

## Sequencer Responsibilities

### Atomicity: Storage Before Finality

The critical failure mode: the EVM commits a transaction (on-chain
commitment exists) but the storage write fails (payload lost). The entity
is on-chain with no backing data — irrecoverable. Disk I/O failures,
backend unavailability, or write errors are all plausible in production.

The sequencer is the sole block producer. It controls when a block is
finalized. This means it can — and must — gate finality on confirmed
storage. The block production pipeline must be:

```
Block production pipeline:

  1. RECEIVE    Collect transactions + sidecars from mempool
  2. VALIDATE   For each payload-bearing op:
                  - Compute commitment from sidecar
                  - Assert matches declared commitment
                  - Reject transaction on mismatch
  3. STAGE      Write all payloads + blob proofs to storage (status = 'pending')
                  - Must be an atomic batch write or within a transaction
                  - Backend examples: postgres BEGIN/COMMIT, pebble WriteBatch,
                    rocksdb WriteBatch, or any store with atomic batch semantics
  4. EXECUTE    Run all transactions in EVM (in-memory state transition)
                  - If any tx reverts: mark its staged entries for rollback
  5. CONFIRM    Commit the storage write
                  - If commit fails: ABORT — discard entire block
                  - Do NOT finalize the block
                  - Re-queue transactions for next block attempt
  6. FINALIZE   Seal block header, broadcast to network
                  - Only reaches here if storage commit succeeded
                  - On-chain state and storage are consistent
```

The invariant: **no block is finalized unless all payload writes are
durable in the storage backend.** The EVM execution (step 4) happens
in-memory — the state transition isn't persisted until the block is sealed
(step 6). If storage fails at step 5, the sequencer discards the
in-memory EVM state and retries with the next block.

```
Failure scenarios:

  Storage write fails (step 5):
    → Block discarded, transactions re-queued
    → No on-chain state change, no data loss
    → Client sees transaction not included, resubmits or waits

  EVM execution fails (step 4, individual tx reverts):
    → Reverted tx's staged payload entries rolled back
    → Other transactions in the block proceed normally
    → Standard EVM revert semantics

  Sequencer crashes between steps 5 and 6:
    → Storage has the data (committed)
    → Block was never finalized (not broadcast)
    → On restart: storage has orphaned 'pending' entries
    → Cleanup: remove entries with status = 'pending' and no matching block
    → Or: promote to 'confirmed' and rebuild block from staged data

  Sequencer crashes after step 6:
    → Both storage and chain are consistent
    → Normal recovery
```

This is a write-ahead pattern: the storage layer is committed before the
execution layer (EVM state) is finalized. The sequencer's advantage over a
general-purpose chain is that it controls both sides — no coordination
protocol needed, just ordering.

### Storage Backend

The storage layer needs two properties:

1. **Atomic batch writes**: All payloads for a block must be written
   atomically — either all succeed or none do. This is the foundation of
   the write-ahead guarantee.

2. **Keyed reads by entity key**: The API serves payloads by entity key.
   Range scans and complex queries are the indexer's job, not the
   sequencer's.

Several backends fit this profile:

| Backend     | Atomic batches | Character                          |
|-------------|----------------|------------------------------------|
| Postgres    | Transactions   | Relational, rich query, mature tooling. Natural if the sequencer already uses it for other state. |
| Pebble      | WriteBatch     | LSM-tree KV store (Go). Used by go-ethereum (geth) for chain state. Fast sequential writes, embedded (no network hop). |
| RocksDB     | WriteBatch     | LSM-tree KV store (C++). Pebble is a Go rewrite of RocksDB's design. Broader language support. |
| BadgerDB    | WriteBatch     | LSM-tree with values separated from keys. Good for large values (payload bytes). |
| SQLite      | Transactions   | Embedded relational. Simpler than postgres, single-writer by nature. |

The choice depends on the sequencer's implementation language and what
it already uses for EVM state. If the sequencer is built on geth (Go),
pebble is the path of least resistance — it's already a dependency and
the write patterns (keyed by entity key, atomic batches per block) map
directly to pebble's WriteBatch API. If the sequencer needs richer
querying or already runs postgres for other reasons, postgres works.

The API layer abstracts this — consumers see HTTP endpoints, not the
storage backend. The backend is an implementation detail that can change
without affecting the protocol.

### Data Model

Regardless of backend, the sequencer stores two logical collections:

```
Data model (conceptual — adapt to backend's key/value or relational model):

  payloads
  ├── entity_key     bytes     (primary key)
  ├── payload        bytes     (reassembled from blobs)
  ├── payload_size   uint32
  ├── block_number   uint32    (block that created/last updated)
  ├── expires_at     uint32    (TTL bound — storage obligation)
  ├── status         enum      ('pending' | 'confirmed')
  └── updated_at     uint32

  payload_blobs
  ├── entity_key     bytes     (references payloads)
  ├── blob_index     uint16    (position within payload)
  ├── commitment     bytes     (48-byte KZG commitment)
  └── proof          bytes     (48-byte KZG proof)
```

For a KV store like pebble, these map to prefixed keys:

```
Key: "payload:<entity_key>"        → payload bytes + metadata
Key: "blob:<entity_key>:<index>"   → commitment + proof
Key: "expiry:<expires_at>:<key>"   → (index for TTL-based cleanup scans)
```

For a relational store, they map to tables with the schema above.

The `status` field tracks write-ahead state:

- `'pending'`: Written during block staging (step 3). Not yet backed by a
  finalized block.
- `'confirmed'`: Block containing this payload was finalized (step 6).
  Safe to serve via API.

On startup recovery, the sequencer scans for `'pending'` entries not backed
by a finalized block and either promotes or deletes them.

The sequencer owns this data completely. No external writes. The
`expires_at` field is the contract's `expiresAt` — the storage obligation
boundary. On DELETE/EXPIRE: remove the payload and all associated blob
entries.

### Entity Lifecycle in Storage

```
CREATE (block N, expiresAt = block N+1000)
  │
  ├── INSERT payload (status = 'pending')
  ├── Block finalized → UPDATE status = 'confirmed'
  │
  ├── EXTEND (block N+500, new expiresAt = N+2000)
  │   UPDATE expires_at = N+2000
  │   Same payload, same blobs — no new writes except metadata
  │
  ├── UPDATE (block N+600, new payload + commitments)
  │   Replace payload + blob entries
  │   (within same atomic batch as block staging)
  │
  └── EXPIRE or DELETE
      DELETE FROM payloads WHERE entity_key = ...
      (cascades to payload_blobs)
```

### Integrity Guarantees

The write-ahead pipeline plus the on-chain commitment create a two-sided
integrity check:

**1. Storage → chain (sequencer guarantees):**

The sequencer will not finalize a block unless the storage backend has
confirmed the write. If the sequencer is honest, every on-chain commitment
has backing data in storage.

**2. Chain → storage (external verification):**

Any node syncing from the sequencer can fetch the payload via the API,
recompute the commitment, and check it against the on-chain value. If
mismatch, the sequencer is provably serving wrong data. This catches a
dishonest or buggy sequencer — the commitment is the contract between the
sequencer and every consumer of its API.

**3. Point-in-time verification:**

Any party can query the API for a payload and its KZG proof. Specific data
elements can be verified via the point evaluation precompile without
retrieving the full payload.

**4. After expiry:**

The sequencer has no obligation to store the payload after expiry. But
historical commitments in the changeset hash chain are permanent on-chain —
they prove a specific payload existed at a specific time, even after the
data is deleted from storage.

### Syncing Nodes

Other nodes that want a copy of entity data don't need to replay the chain.
They query the sequencer's API, which reads from the storage backend:

```
GET /entities/:entityKey/payload   → raw bytes
GET /entities/:entityKey/proof     → witness proof
GET /entities/:entityKey           → metadata + commitment
```

A syncing node can verify any response against the on-chain commitment. The
API is the interface — the storage backend is an implementation detail. Nodes
building their own query layer (e.g., an indexer with its own schema) fetch
payloads from the API and store them in whatever representation suits their
access patterns.

```
┌───────────┐     ┌───────────────────────────────────┐
│  Client   │────▶│          Sequencer                 │
│           │     │                                     │
│  tx +     │     │  EVM ──▶ storage (payloads)        │
│  sidecar  │     │   │         │                       │
└───────────┘     │   │         ▼                       │
                  │   │      API ──▶ syncing nodes      │
                  │   ▼                                  │
                  │  L1 (state roots, changeset hashes) │
                  └───────────────────────────────────┘
```

The simplicity here is intentional. The sequencer is the sole block producer
and the sole writer to storage. It doesn't need consensus with other nodes
about payload storage — it just needs to serve correct data that matches
on-chain commitments. Any node can verify independently.

---

## Impact on DELETE and EXPIRE Operations

### Current Behavior

- **DELETE**: Owner removes entity before expiry. Commitment zeroed from storage.
  Changeset chain preserves the final entityHash.
- **EXPIRE**: Anyone removes an expired entity. Same storage cleanup.

### With Payload Commitments

Since the sequencer controls block production and knows which entities have
expired, it can automate expiry:

**Option 1: Sequencer-initiated EXPIRE (automated pruning)**

At the end of each block (or in a periodic maintenance transaction), the
sequencer scans for entities whose `expiresAt <= current block` and
submits EXPIRE operations. This transforms EXPIRE from a user-initiated
housekeeping operation into a sequencer-automated one.

```
Block N processing:
  1. Execute user transactions (CREATE, UPDATE, EXTEND, TRANSFER, DELETE)
  2. Sequencer appends EXPIRE ops for all newly-expired entities
  3. DELETE FROM payloads WHERE entity_key IN (expired keys)
```

The EXPIRE operation remains in the contract — it's just always called by the
sequencer address rather than arbitrary users. The access control doesn't
change (EXPIRE already allows any caller). The storage deletion is the
sequencer's own cleanup — it happens after the EVM execution confirms the
on-chain commitment is zeroed.

**Option 2: DELETE becomes a soft-delete**

If the sequencer automates expiry, explicit DELETE becomes less critical for
storage reclamation. DELETE could be reframed as:

- **Reduce expiresAt to current block** (making the entity immediately
  eligible for sequencer-automated EXPIRE)
- Or retain current behavior (immediate commitment zeroing)

The second option (retain current DELETE) is simpler and doesn't change
semantics. DELETE remains useful for: "I want this gone now, not at expiry."

**Recommendation:** Keep DELETE as-is. Add sequencer-automated EXPIRE as a
block-level operation. The two serve different purposes:

- DELETE = owner-initiated immediate removal ("I want this gone")
- EXPIRE = sequencer-automated TTL enforcement ("time's up")

The sequencer can restrict EXPIRE to its own address if desired (via a
modifier), but the current permissionless design is fine — it just means
the sequencer handles it so users don't have to.

---

## Sequencer as DB-Chain

### Architecture

The sequencer is a single-application chain where the EVM handles
commitments and access control, and a storage backend handles data. There's
no distributed storage protocol — the sequencer owns both the chain and the
store.

```
┌──────────────────────────────────────────────────────────────┐
│                        Sequencer                              │
│                                                               │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐  │
│  │ Payload  │   │   EVM    │   │ Storage  │   │   API    │  │
│  │ Ingress  │──▶│ (entity  │──▶│ (payload │──▶│ (query   │  │
│  │ (sidecar)│   │  registry│   │  + proof │   │  + sync) │  │
│  └──────────┘   │  contract│   │  store)  │   └────┬─────┘  │
│                  └────┬─────┘   └──────────┘        │        │
│                       │                             │        │
│                 ┌─────▼──────┐              ┌───────▼──────┐ │
│                 │ State root │              │ Syncing      │ │
│                 │ + changeset│              │ nodes /      │ │
│                 │ hash       │              │ indexers     │ │
│                 └─────┬──────┘              └──────────────┘ │
│                       │                                      │
└───────────────────────┼──────────────────────────────────────┘
                        │
                   ┌────▼────┐
                   │   L1    │
                   │ (state  │
                   │  roots, │
                   │  hashes)│
                   └─────────┘
```

**EVM**: Runs the EntityRegistry contract. Sees only commitments and
metadata — never payload bytes. Produces the changeset hash chain and
entity commitments.

**Storage**: Payload bytes, witness proofs, and metadata. The sequencer
writes on CREATE/UPDATE and deletes on DELETE/EXPIRE. Single-writer —
no contention, no replication conflicts. Backend can be an embedded KV
store (pebble, rocksdb, badger), a relational DB (postgres, sqlite), or
anything with atomic batch write semantics.

**API**: Serves payload data and proofs to syncing nodes and indexers. Reads
from the storage backend. Responses are independently verifiable against
on-chain commitments.

**L1 settlement**: State roots and changeset hashes posted periodically.
Any party can verify the sequencer's state against L1.

### Data Flow

```
1. Client submits:
   - Transaction: execute([{CREATE, payloadCommitment: 0x..., ...}])
   - Sidecar: raw payload bytes

2. Sequencer validates:
   - Compute commitment from sidecar payload
   - Verify it matches payloadCommitment in transaction
   - Reject on mismatch

3. Sequencer executes:
   - Run transaction in EVM
   - Contract hashes payloadCommitment into coreHash
   - Emit EntityOperation event

4. Sequencer writes to storage:
   - Store payload, commitment, proof keyed by entity key
   - On UPDATE: overwrite existing entry
   - On DELETE/EXPIRE: remove entry

5. Sequencer settles to L1:
   - Post state root + changeset hash

6. Syncing nodes:
   - Subscribe to events (via RPC or websocket)
   - Fetch payloads from sequencer API
   - Verify commitment against on-chain value
   - Build their own query representation
```

### Rollup Security Model

The changeset hash chain and state roots posted to L1 form the security
basis. The trust model scales with the verification approach:

**Optimistic (fraud proof):** The sequencer posts state commitments to L1.
During a challenge window, any party with access to the payload data (from
the API or their own copy) can submit a fraud proof showing state divergence.
The on-chain commitment lets the fraud proof reference specific payloads
without re-uploading them.

**Validity (ZK proof):** The sequencer generates a ZK proof that state
transitions are correct. Payload availability is still needed for indexers
to serve queries, but the proof itself attests to execution correctness
independently.

**Redundancy (future):** If the single-sequencer trust model is insufficient,
additional nodes can mirror the storage via the API and attest to
data availability. This doesn't require protocol changes — just more readers
of the same API, each verifying against on-chain commitments.

### Throughput

With payload bytes out of calldata, the two throughput dimensions decouple:

| Dimension          | Bottleneck                    | Approximate capacity         |
|--------------------|-------------------------------|------------------------------|
| EVM (commitments)  | Block gas limit (tunable)     | ~770 CREATEs/block at 30M gas |
| Data (payloads)    | Network + storage write I/O   | 100s of MB/s (SSD-backed)   |
| Proof computation  | CPU (parallelizable)          | ~42ms per 128 KiB blob      |

The gas limit bounds how many entities can be created per block. The data
layer bounds how much content can be stored. These are independent — a block
with 100 CREATEs of 1 MiB payloads each costs the same gas as 100 CREATEs
of 1 byte payloads. The storage backend handles the actual data difference.

**Block gas limit is a tuning parameter, not a fixed constraint.** On an
application-specific chain, the sequencer operator controls the block gas
limit. Since the only contract is the EntityRegistry and payloads are no
longer in calldata, the per-operation gas cost is small and predictable
(~39k gas per CREATE). The operator can scale the gas limit to match the
sequencer's actual execution capacity:

| Block gas limit | CREATEs/block | CREATEs/s (2s blocks) | Write speed @ 100 KB avg | Write speed @ 1 MiB avg |
|-----------------|---------------|----------------------|--------------------------|-------------------------|
| 30M (Ethereum)  | ~770          | ~385/s               | ~37.5 MB/s               | ~385 MB/s               |
| 100M            | ~2,560        | ~1,280/s             | ~125 MB/s                | ~1.25 GB/s              |
| 500M            | ~12,800       | ~6,400/s             | ~625 MB/s                | ~6.25 GB/s *            |
| 1B              | ~25,600       | ~12,800/s            | ~1.25 GB/s *             | ~12.5 GB/s *            |

`*` = exceeds typical SSD sequential write throughput (~500 MB/s SATA,
~3.5 GB/s NVMe). At these levels storage I/O becomes the bottleneck,
not EVM execution. Actual throughput is min(EVM capacity, disk write
speed, network ingress).

The practical ceiling is wherever EVM execution time (commitment hashing,
SSTOREs, event emission) exceeds the target block time, or where storage
I/O saturates. With ~39k gas per operation and no payload processing in
the EVM, the execution is lightweight — the gas limit can be pushed
significantly higher than Ethereum L1's 30M without risking block
production delays. At moderate gas limits (30M–100M) the EVM is the
bottleneck. At aggressive limits (500M+) the bottleneck shifts to
storage write throughput and proof computation.

---

## Payload Size Limits and Storage Accounting

Without calldata as a natural constraint, the system needs explicit payload
size governance. With `PAYLOADSIZE` available to the contract, enforcement
can happen at two layers:

### Layer 1: Sequencer pre-validation (mempool policy)

The sequencer rejects transactions before block inclusion if sidecar
payloads exceed policy limits. These are configurable and can be changed
without contract upgrades:

| Parameter             | Suggested value | Rationale                         |
|-----------------------|-----------------|-----------------------------------|
| Max payload per op    | 10 MiB          | Single content upload bound       |
| Max payload per tx    | 25 MiB          | Batch upload bound                |
| Max payload per block | 128 MiB         | Disk write throughput bound       |

### Layer 2: Contract-enforced limits (consensus rules)

With `PAYLOADSIZE`, the contract can enforce hard limits that are part of
the state transition function — not just sequencer policy:

```solidity
uint256 public constant MAX_PAYLOAD_BYTES = 10_485_760;  // 10 MiB
uint256 public constant MIN_TTL_BLOCKS = 100;

function _create(Operation calldata op, BlockNumber current, uint256 sidecarIdx)
    internal returns (bytes32, bytes32)
{
    uint256 size = payloadSize(sidecarIdx);
    if (size == 0) revert EmptyPayload();
    if (size > MAX_PAYLOAD_BYTES) revert PayloadTooLarge(size, MAX_PAYLOAD_BYTES);

    // TTL-proportional storage obligation check
    uint256 ttlBlocks = BlockNumber.unwrap(op.expiresAt) - BlockNumber.unwrap(current);
    if (ttlBlocks < MIN_TTL_BLOCKS) revert TTLTooShort(ttlBlocks, MIN_TTL_BLOCKS);

    // ... rest of create
}
```

Contract-level enforcement means a compromised or misconfigured sequencer
cannot include transactions that violate size limits — the EVM rejects them
during execution. This is the same guarantee that gas limits provide on
Ethereum L1.

### Storage Accounting Model

The sequencer's real cost is disk-space-over-time: storing N bytes for T
blocks. The contract can track this and price accordingly:

```
Storage cost ∝ payloadSize × TTL

For a 1 MiB payload with TTL of 1000 blocks:
  storage_units = 1,048,576 bytes × 1000 blocks = 1,048,576,000 byte-blocks
```

With `PAYLOADSIZE` the contract can maintain a running storage ledger:

```solidity
// Track total outstanding storage obligation
uint256 public totalStorageUnits;

// Per-entity tracking (optional — stored in commitment or separate mapping)
mapping(bytes32 entityKey => uint256 storageUnits) internal _entityStorage;
```

On CREATE: add `size * ttl` to the ledger.
On EXTEND: add `size * (newExpiry - oldExpiry)` (size from stored metadata).
On DELETE/EXPIRE: subtract remaining obligation.

### Admin-Controlled Storage Cap

The sequencer operator knows their actual infrastructure costs — disk
capacity, IOPS budget, backup overhead. The contract should reflect this
via a permissioned admin function that sets the upper bound on total
outstanding storage:

```solidity
address public admin;  // sequencer operator

uint256 public storageCap;         // max total byte-blocks outstanding
uint256 public totalStorageUnits;  // current outstanding byte-blocks

function setStorageCap(uint256 newCap) external {
    require(msg.sender == admin);
    storageCap = newCap;
}
```

Every CREATE and EXTEND checks `totalStorageUnits + delta <= storageCap`
before proceeding. This gives the operator a hard ceiling they can adjust
as infrastructure scales up or down.

### Backpressure Pricing

A hard cap is a blunt instrument — it's either open or full. A more useful
model is a pricing curve that increases cost as utilization approaches the
cap, creating incremental backpressure:

```
                     ▲ storage fee multiplier
                     │
                     │                          ╱
                     │                        ╱
                     │                      ╱
                     │                   ╱
                     │               ╱
                     │           ╱
                 1x  │─────╱
                     │
                     └──────────────────────────▶ utilization
                     0%                        100%
                                           (storageCap)
```

The fee multiplier scales with how full the system is. When utilization is
low, storage is cheap (base rate). As it approaches the cap, the multiplier
increases — reflecting that the sequencer's marginal cost of additional
storage rises as it approaches infrastructure limits.

**Linear model (simple):**

```
multiplier = 1 + (utilization / storageCap) * MAX_PREMIUM

At 50% full: multiplier = 1 + 0.5 * MAX_PREMIUM
At 90% full: multiplier = 1 + 0.9 * MAX_PREMIUM
```

**Exponential model (EIP-1559-style):**

```
multiplier = e^(k * utilization / storageCap)

Where k controls curve steepness. Similar to EIP-1559's
base_fee = MIN_FEE * e^(excess / UPDATE_FRACTION)
```

The exponential model is well-understood from EIP-1559 and has the right
property: gentle at low utilization, aggressive near the cap. The admin
controls the cap; the curve controls the economics within it.

```solidity
// Storage fee charged on CREATE/EXTEND (in native token or storage credits)
function storageFee(uint256 sizeBytes, uint256 ttlBlocks) public view returns (uint256) {
    uint256 units = sizeBytes * ttlBlocks;
    uint256 baseFee = units * BASE_RATE_PER_UNIT;
    uint256 utilization = totalStorageUnits * SCALE / storageCap;
    // Exponential multiplier: baseFee * e^(k * utilization / SCALE)
    return baseFee * exp(k * utilization / SCALE) / SCALE;
}
```

The admin can also adjust `BASE_RATE_PER_UNIT` to reflect actual
infrastructure costs. This makes storage pricing a direct pass-through of
the sequencer operator's costs to users, with the curve providing market-
based rationing when demand approaches capacity.

### Interaction with EIP-1559 Transaction Basefee

The sequencer chain inherits EIP-1559 gas pricing for the EVM execution
layer. This creates two independent fee dimensions:

```
Total user cost = gas fee (EIP-1559) + storage fee (utilization curve)

Where:
  gas fee     = gas_used × basefee          (EVM execution: commitments, SSTOREs)
  storage fee = f(payload_size, ttl, util)  (sequencer storage obligation)
```

**Why two dimensions work better than one:**

With payload in calldata (current model), there's only one fee dimension:
gas. A user submitting 10 small entities in one transaction pays a single
basefee but high calldata cost. A user submitting 10 transactions pays 10x
the basefee. This creates a perverse incentive to batch everything into
single large transactions.

With payload commitments, the expensive part (storage) is per-operation,
not per-transaction. The basefee covers EVM execution only — and each
CREATE/EXTEND operation within a batch carries its own storage fee based on
payload size and TTL. Batching multiple operations into one transaction
saves on basefee (one tx overhead instead of many) without gaming storage
costs.

```
Per-tx cost comparison:

  Current (payload in calldata):
    1 tx × 3 CREATEs:  basefee × 1 + calldata(payload_0 + payload_1 + payload_2)
    3 tx × 1 CREATE:   basefee × 3 + calldata(payload_0) + ... + calldata(payload_2)
    → Batching saves 2× basefee AND packs calldata more efficiently
    → Strong incentive to batch, penalizes small frequent uploads

  Proposed (payload commitments):
    1 tx × 3 CREATEs:  basefee × 1 + storage_fee(p0) + storage_fee(p1) + storage_fee(p2)
    3 tx × 1 CREATE:   basefee × 3 + storage_fee(p0) + storage_fee(p1) + storage_fee(p2)
    → Batching saves 2× basefee only (small — ~21k gas × basefee per tx)
    → Storage fees identical either way — per-op, not per-tx
    → Users choose batch vs individual based on atomicity needs, not cost gaming
```

This separation means the basefee auction operates on a much smaller gas
surface (commitments + SSTOREs + events, ~39k gas per CREATE). The basefee
stays low because the heavy cost (payload storage) has its own fee market.
Block space contention is about operation throughput, not data throughput.

**Basefee dynamics in an application-specific chain:**

Because the sequencer is the sole block producer, the EIP-1559 basefee
mechanism behaves differently than on Ethereum L1:

- No competing applications — all gas is EntityRegistry operations.
- The sequencer controls block gas limit and can tune it to the contract's
  actual execution profile.
- Basefee will converge to a level reflecting demand for operation slots,
  not demand for generic blockspace.
- During low demand, basefee drops to the protocol minimum. The storage fee
  still applies — the sequencer's disk costs don't go to zero when the
  chain is quiet.

The two-fee model means the sequencer can price its real costs (storage is
expensive, compute is cheap) rather than collapsing everything into gas.

### Non-Zero Byte Accounting

If the full `PAYLOAD_INFO` precompile is available (with `nonZeroBytes`),
the storage fee can weight dense data higher than sparse data:

```
Effective size = nonZeroBytes × DENSE_WEIGHT + zeroBytes × SPARSE_WEIGHT

Where:
  DENSE_WEIGHT  = 4   (incompressible data, higher disk cost)
  SPARSE_WEIGHT = 1   (compressible, lower effective cost)
```

This mirrors Ethereum's own calldata pricing (16 gas/non-zero byte vs
4 gas/zero byte) and incentivizes clients to avoid padding payloads with
non-zero filler. The effective size feeds into the storage fee calculation
in place of raw `totalBytes`.

---

## Off-Chain Indexer / Syncing Nodes

### Current Model

```
1. Subscribe to EntityOperation events
2. For CREATE/UPDATE: decode payload from transaction calldata
3. Store entity data in local database
4. Verify local state against changeSetHash()
```

### Proposed Model

```
1. Subscribe to EntityOperation events
2. For CREATE/UPDATE: fetch payload from sequencer API
3. Verify payload against on-chain payloadCommitment
4. Store entity data in local database (own schema, own representation)
5. Verify local state against changeSetHash()
```

The indexer fetches payload from the sequencer's API
rather than decoding it from calldata. This is a simpler dependency — a
single HTTP endpoint — and removes the need for archival node access.

### Verification

Any node can independently verify that the sequencer is serving correct data:

```
For each CREATE/UPDATE event:
  1. GET /entities/:entityKey/payload from sequencer API
  2. Compute commitment locally from the returned bytes
  3. Compare against on-chain payloadCommitment
  4. If mismatch: sequencer is provably serving wrong data
```

This is stronger than the current model. Today, calldata is inherently
correct (the EVM guarantees it). With the commitment model, the indexer
actively verifies the sequencer — the commitment is the contract between
the sequencer and every consumer of its API.

---

## Migration Path

### Phase 1: Add payloadCommitment to Operation struct

- Add `bytes32 payloadCommitment` field to `Operation`
- Require `payloadCommitment == keccak256(payload)` in CREATE/UPDATE
- Both fields coexist — backwards compatible
- Zero contract risk — just an additional check

### Phase 2: Sequencer sidecar protocol

- Sequencer accepts payload via sidecar channel
- Sequencer validates commitment before inclusion
- Clients stop sending payload in calldata
- Contract stops reading `payload` field — uses `payloadCommitment` only

### Phase 3: Remove payload from calldata

- Remove `bytes payload` from Operation struct
- Update CORE_HASH_TYPEHASH (breaking change to hash scheme)
- Update all tests and cross-language encoding specs
- Deploy new contract version

### Phase 4: KZG commitment (optional upgrade)

- Replace `keccak256(payload)` commitment with KZG versioned hash
- Add point evaluation verification path for disputes
- Enable DAS if sequencer network grows

---

## Open Questions

1. **Commitment scheme finality**: Should the contract enforce a specific
   commitment scheme (e.g., require versioned hash format 0x01...), or
   accept any `bytes32` and leave validation to the sequencer?

2. **Multi-blob payloads**: For payloads exceeding 128 KiB (one KZG blob),
   should the contract accept a single aggregated commitment or an array of
   per-blob commitments?

3. **Sequencer rotation**: If the sequencer is replaced, how are payload
   storage obligations transferred? The new sequencer needs all payload
   data for active entities.

4. **Redundancy**: Should the system require N-of-M storage attestation
   (data availability committee) from launch, or start with a single
   sequencer and add redundancy later?

5. **Proof-of-storage**: Should the sequencer periodically prove it still
   holds payload data (e.g., respond to random challenges), or is the
   initial witness proof sufficient?

6. **UPDATE semantics**: When an entity is updated, should the old payload
   be retained (historical access) or immediately prunable? The old
   `coreHash` is replaced — only the changeset chain references the old
   entityHash.

7. **Payload addressing**: Should payloads be content-addressed
   (`keccak256(payload)` as the key) or entity-addressed (entity key +
   version as the key)? Content addressing enables deduplication but
   complicates deletion.

8. **Gas limit implications**: With payloads out of calldata, what should
   the sequencer's block gas limit be? The current Ethereum-default 30M
   may be artificially low for an application-specific chain that doesn't
   need gas for payload data.

9. **Precompile vs opcode surface area**: The `PAYLOADHASH` / `PAYLOADSIZE`
   opcodes are the minimal viable surface. Should we also expose:
   - `PAYLOADCOUNT()` — number of sidecar entries in this tx (for batch
     validation without counting manually)?
   - Content-type or MIME hash from the sidecar (or is calldata sufficient
     for metadata)?
   - A `PAYLOAD_SLICE(index, offset, length)` precompile for bounded reads
     (e.g., reading just a header prefix without full payload access)?

10. **Sidecar ordering guarantees**: With implicit indexing, the sidecar
    order must match the operation order exactly. If the sequencer reorders
    operations for optimization (e.g., grouping by entity key), the sidecar
    indices shift. Should the protocol forbid operation reordering, or use
    explicit indices to allow it?

11. **Storage accounting granularity**: Should storage tracking be
    per-entity (allowing per-entity quotas and billing) or aggregate-only
    (simpler, less state)? Per-entity tracking adds one mapping slot per
    entity but enables the contract to subtract storage units on
    DELETE/EXPIRE precisely.

12. **Commitment in Commitment struct**: Should the on-chain `Commitment`
    store the `payloadSize` alongside `coreHash`? This would let EXTEND
    operations adjust storage accounting without a `PAYLOADSIZE` call (the
    original size is needed to compute the delta). Adds 32 bytes (one slot)
    to the commitment but avoids re-reading sidecar metadata for lifecycle
    operations that don't carry a new payload.

---

## References

- [EIP-4844: Shard Blob Transactions](https://eips.ethereum.org/EIPS/eip-4844)
- [EIP-7594: PeerDAS](https://eips.ethereum.org/EIPS/eip-7594)
- [EIP-7623: Increase Calldata Cost](https://eips.ethereum.org/EIPS/eip-7623)
- [KZG Polynomial Commitments — Dankrad Feist](https://dankradfeist.de/ethereum/2020/06/16/kate-polynomial-commitments.html)
- [c-kzg-4844 Reference Implementation](https://github.com/ethereum/c-kzg-4844)
- [Paradigm: Data Availability Sampling](https://www.paradigm.xyz/2022/08/das)
- [Nomos: FRI-based Commitments for DA](https://blog.nomos.tech/fri-based-commitments-for-data-availability/)
