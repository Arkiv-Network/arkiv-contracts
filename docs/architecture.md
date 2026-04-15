# Arkiv EntityRegistry Architecture

## Overview

The Arkiv EntityRegistry is a smart contract that provides a verifiable
commitment layer for an off-chain database. Entities — content with typed
metadata — are created, modified, and removed through on-chain transactions.
The contract stores only a minimal cryptographic commitment for each entity;
full content lives in transaction calldata and is indexed off-chain by
database nodes.

A rolling changeset hash accumulates every mutation, giving any node a way
to verify its local database against the canonical on-chain state at any
granularity: per-operation, per-transaction, or per-block.

```
                          +--------------------------+
                          |     EntityRegistry       |
                          |                          |
    execute(ops[])  ----->|  dispatch + hash chain   |
                          |  commitments (3 slots)   |
                          |  changeset snapshots     |
                          |  block linked list       |
                          +-----------+--------------+
                                      |
                          EntityOp events + calldata
                                      |
                          +-----------v--------------+
                          |     Off-chain DB Node    |
                          |                          |
                          |  index events            |
                          |  reconstruct entities    |
                          |  verify changeset hash   |
                          +--------------------------+
```

---

## Entity Model

An entity represents a piece of content with structured metadata. Each entity
has an immutable identity (who created it, when, what content) and mutable
lifecycle fields (current owner, expiry).

### Entity Key

Every entity is identified by a globally unique key derived from:

```
entityKey = keccak256(chainId || registryAddress || ownerAddress || nonce)
```

The owner's nonce increments monotonically on each create, guaranteeing
uniqueness without existence checks.

### On-chain Commitment

The contract stores a minimal commitment per entity — enough to recompute
the entity's cryptographic hash from chain state alone:

```
+--------------------------------------------------------------+
| Commitment                                                   |
+--------------------------------------------------------------+
| creator    | address  | who created the entity (immutable)   |
| createdAt  | uint32   | block of creation (immutable)        |
| updatedAt  | uint32   | block of last mutation               |
| expiresAt  | uint32   | block when entity expires            |
| owner      | address  | current owner                        |
| coreHash   | bytes32  | hash of immutable content            |
+--------------------------------------------------------------+
```

### Off-chain Content

The full entity data — payload bytes, MIME content type, and typed
attributes — is passed in calldata and emitted in events. It is never
stored on-chain. Off-chain nodes reconstruct the complete entity from
transaction data.

### Attributes

Entities carry up to 32 typed key-value attributes:

| Value Type   | Description                        |
|--------------|------------------------------------|
| UINT         | 256-bit unsigned integer           |
| STRING       | UTF-8 string (up to 128 bytes)     |
| ENTITY_KEY   | Reference to another entity        |

Attribute names are validated identifiers (`a-z`, `0-9`, `.`, `-`, `_`,
lowercase only, max 32 bytes). They must be sorted ascending by name —
this enforces uniqueness and produces deterministic hashes regardless of
which SDK or language constructs the transaction.

---

## Entity Lifecycle

An entity moves through a defined set of states via six operation types.
All operations are submitted through a single `execute(operations[])` entry
point that accepts batches.

```
                    +---------+
                    |  CREATE |
                    +----+----+
                         |
                         v
          +-----> [ ACTIVE ] <-----+
          |         |  |  |        |
       EXTEND    UPDATE  TRANSFER  |
          |         |     |        |
          +---------+-----+--------+
                    |
          +---------+---------+
          |                   |
          v                   v
    [ DELETED ]         [ EXPIRED ]
    (by owner)        (by anyone after
                       expiry block)
```

### Operations

**CREATE** — Mint a new entity. The caller becomes both creator and owner.
Requires a future expiry block, valid content type, and valid attributes.

**UPDATE** — Replace the entity's content (payload, content type,
attributes). Only the owner can update. Does not change ownership or expiry.
The content hash is fully recomputed.

**EXTEND** — Push the expiry further into the future. Only the owner can
extend. The new expiry must be strictly greater than the current one. Does
not touch content.

**TRANSFER** — Change the entity's owner. Only the current owner can
transfer. The previous owner loses all access immediately.

**DELETE** — Remove the entity before it expires. Only the owner can delete.
The commitment is zeroed from storage.

**EXPIRE** — Remove an entity that has passed its expiry block. Callable by
anyone — no ownership check. This is a housekeeping operation that reclaims
storage.

### Access Control

| Operation | Caller must be | Entity must be |
|-----------|---------------|----------------|
| CREATE    | anyone        | (new)          |
| UPDATE    | owner         | active         |
| EXTEND    | owner         | active         |
| TRANSFER  | owner         | active         |
| DELETE    | owner         | active         |
| EXPIRE    | anyone        | expired        |

"Active" means the entity exists and its expiry block has not been reached.

---

## Transaction Flow

All mutations flow through `execute()`, which accepts an array of operations
and processes them atomically.

```
execute(operations[])
  |
  |  1. Validate batch is non-empty
  |
  |  2. Read previous changeset hash
  |
  |  3. Block bookkeeping
  |     - New block? Advance the block linked list
  |     - Same block? Continue the transaction sequence
  |
  |  4. For each operation:
  |     +------------------------------------------+
  |     |  _dispatch(op)                           |
  |     |    route by operationType                |
  |     |    validate guards (exists, active,      |
  |     |      owner, expiry)                      |
  |     |    compute hashes                        |
  |     |    update commitment storage             |
  |     |    emit EntityOp event                   |
  |     |    return (entityKey, entityHash)         |
  |     +------------------------------------------+
  |     |
  |     |  Chain the hash:
  |     |    hash = keccak256(hash || opType || key || entityHash)
  |     |
  |     |  Store snapshot:
  |     |    _hashAt[block, txSeq, opSeq] = hash
  |     |
  |
  |  5. Record operation count for this transaction
  |
  done
```

A single `execute()` call may contain multiple operations. They are
processed sequentially — the changeset hash chains through every operation
in order. If any operation reverts, the entire transaction is rolled back.

---

## Two-Level Entity Hashing

Entity hashes use EIP-712 structured data with a two-level design that
separates immutable content from mutable lifecycle fields.

```
+-------------------------------------------------------+
|                     entityHash                        |
|  EIP-712 domain-wrapped hash of:                     |
|                                                       |
|  +------------------+   +---------------------------+ |
|  |    coreHash      |   |    mutable fields         | |
|  |                  |   |                           | |
|  |  entityKey       |   |  owner                    | |
|  |  creator         |   |  updatedAt                | |
|  |  createdAt       |   |  expiresAt                | |
|  |  contentType     |   |                           | |
|  |  payload         |   |                           | |
|  |  attributesHash  |   |                           | |
|  +------------------+   +---------------------------+ |
|       (immutable)              (changes on           |
|                            extend/transfer)           |
+-------------------------------------------------------+
```

**Why two levels?** Operations that only change owner or expiry (EXTEND,
TRANSFER) can recompute the entityHash from the stored `coreHash` without
needing the full payload or attributes. This means those operations never
need to query an off-chain database — everything required is already in
contract storage.

UPDATE is the only operation that recomputes `coreHash`, because it
replaces the content entirely.

---

## Changeset Hash Chain

Every mutation is accumulated into a rolling hash chain. This provides a
single value that commits to the entire history of all entity operations.

```
hash_0 = keccak256(0x00...00 || opType_0 || key_0 || entityHash_0)
hash_1 = keccak256(hash_0   || opType_1 || key_1 || entityHash_1)
hash_2 = keccak256(hash_1   || opType_2 || key_2 || entityHash_2)
  ...
hash_N = keccak256(hash_N-1 || opType_N || key_N || entityHash_N)
```

The chain starts from zero and grows with every operation, across all
transactions and blocks. It never branches or rewinds.

### Three-Level Lookup

Every intermediate hash is stored and queryable at three granularities:

```
+------------------------------------------------------------------+
|  Block 100                                                       |
|  +------------------------------------------------------------+  |
|  | Tx 0 (3 ops)                                               |  |
|  |   op 0: hash_a   <-- changeSetHashAtOp(100, 0, 0)         |  |
|  |   op 1: hash_b   <-- changeSetHashAtOp(100, 0, 1)         |  |
|  |   op 2: hash_c   <-- changeSetHashAtTx(100, 0)            |  |
|  +------------------------------------------------------------+  |
|  | Tx 1 (2 ops)                                               |  |
|  |   op 0: hash_d   <-- changeSetHashAtOp(100, 1, 0)         |  |
|  |   op 1: hash_e   <-- changeSetHashAtTx(100, 1)            |  |
|  +------------------------------------------------------------+  |
|                                                                  |
|  changeSetHashAtBlock(100) = hash_e                              |
+------------------------------------------------------------------+
```

- **Per-operation**: the hash after each individual operation
- **Per-transaction**: the hash after the last operation in a transaction
  (derived from the per-op snapshot + operation count)
- **Per-block**: the hash after the last operation in the last transaction
  of a block (derived from the per-tx hash + transaction count)

Transaction-level and block-level hashes are not stored separately — they
are derived from per-operation snapshots using counts. This avoids
redundant storage while keeping all three levels queryable.

### Block Linked List

Only blocks that contain mutations are tracked. A doubly-linked list
connects them for traversal:

```
  genesis -----> block 100 -----> block 247 -----> block 300
  (deploy)       (3 ops)          (1 op)           (5 ops)
            <-----          <-----           <-----
```

Blocks without entity operations are not stored. This enables efficient
traversal without scanning every block number.

---

## Off-chain Database Indexing

The contract is designed so that an off-chain database can reconstruct and
verify all entity state from on-chain data.

### Event-Driven Indexing

Every operation emits an `EntityOp` event:

```
event EntityOp(
    bytes32 indexed entityKey,
    uint8   indexed operationType,
    address indexed owner,
    BlockNumber     expiresAt,
    bytes32         entityHash
)
```

A database node processes these events in order:

1. **Decode the event** — extract operation type, entity key, owner,
   expiry, entity hash
2. **Read calldata** — for CREATE and UPDATE, extract the full payload,
   content type, and attributes from the transaction's calldata
3. **Apply the operation** — insert, update, or remove the entity in the
   local database
4. **Verify the hash** — recompute the changeset hash locally and compare
   against the contract's stored snapshot

### Verification at Any Granularity

A syncing node can verify its state against the contract at three levels:

```
Local DB hash  ==  contract.changeSetHashAtOp(block, tx, op)    exact op
Local DB hash  ==  contract.changeSetHashAtTx(block, tx)        end of tx
Local DB hash  ==  contract.changeSetHashAtBlock(block)          end of block
Local DB hash  ==  contract.changeSetHash()                      current head
```

If a mismatch is detected, the node can binary-search the block linked
list to find the exact point of divergence, then drill down to the
transaction and operation level.

### What Lives Where

| Data                    | On-chain                       | Off-chain              |
|-------------------------|--------------------------------|------------------------|
| Entity existence        | Commitment (3 storage slots)   | Full entity record     |
| Payload bytes           | Calldata only                  | Indexed + queryable    |
| Content type            | Calldata only                  | Indexed + queryable    |
| Attributes              | Calldata only                  | Indexed + queryable    |
| Owner / expiry          | Commitment fields              | Mirrored from events   |
| Content hash            | Commitment.coreHash            | Recomputed + verified  |
| Changeset hash          | Per-op snapshots               | Recomputed + compared  |
| Block traversal         | Linked list + counts           | Event log scanning     |

---

## Determinism Guarantees

The system enforces deterministic hashing across all implementations
through validation at the contract boundary:

- **Attribute names**: Charset restricted to `a-z`, `0-9`, `.`, `-`, `_`.
  No uppercase, no ambiguity.
- **Attribute ordering**: Strict ascending sort enforced on-chain. Same
  attributes always produce the same hash.
- **Content types**: RFC 2045 MIME grammar, lowercase only. `text/plain`
  and `Text/Plain` cannot both enter the system.
- **Identifier encoding**: Left-aligned, zero-padded to fixed widths.
  No trailing garbage bytes.
- **EIP-712 structured hashing**: Industry-standard encoding implemented
  in every major language. No custom serialization.

Any SDK that follows EIP-712 and respects the validation rules will produce
identical hashes to the contract.
