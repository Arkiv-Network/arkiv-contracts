# EntityRegistry Contract Specification

This document specifies the EntityRegistry smart contract — the single on-chain entry point for all entity write operations in the Arkiv protocol.

The contract implements two protocol primitives:
1. **Entity Commitment Map** — a mapping from entity key to entity hash, owner, and expiry
2. **Change Set Hash** — a per-block cumulative hash over all entity mutations

All entity state changes flow through this contract. There is no other write path.

---

## 1. Scope

**In scope:**
- Entity lifecycle operations: create, update, extend expiry, change ownership, delete
- Batch API for multiple operations per transaction
- $GLM payment enforcement per entity operation
- Entity commitment map maintenance (store/update/remove entries)
- Change set hash accumulation per block
- Event emission for off-chain DB derivation
- Owner validation (signer == owner for all mutations)
- Expiry validation (reject operations on expired entities)

**Out of scope (separate contracts):**
- Challenge game and dispute resolution
- Validator registry and staking
- $GLM paymaster (account abstraction)
- Query predicate evaluation (challenge game concern)

---

## 2. Entity Data Model

### 2.1 Entity Key

The entity key uniquely identifies an entity. It is a `bytes32` value computed as:

```
entityKey = keccak256(abi.encodePacked(block.chainid, address(this), owner, nonce))
```

Where:
- `block.chainid`: `uint256` — prevents cross-chain key collisions
- `address(this)`: `address` — prevents collisions across multiple EntityRegistry deployments
- `owner`: `address` — the transaction signer at creation time. Immutable after creation.
- `nonce`: `uint32` — per-owner nonce, incremented on each entity creation

The per-owner nonce makes the key predictable client-side before submission: a user can read their current nonce and compute their next entity key without waiting for tx inclusion. A global nonce would require waiting for tx inclusion since concurrent submissions from different owners would contend on the same value.

The entity key is deterministic and computable identically by the contract and the off-chain DB.

### 2.2 Entity Commitment

Each entity has a commitment stored on-chain:

```solidity
struct Entity {
    address     creator;      // immutable after creation
    address     owner;        // mutable via changeOwner
    BlockNumber createdAt;    // immutable after creation
    BlockNumber updatedAt;    // updated on every mutation
    BlockNumber expiresAt;    // updated on extend
    bytes32     coreHash;     // EIP-712 hash of immutable fields (key, creator, createdAt, contentType, payload, attributes)
}
```

`BlockNumber` is a custom type wrapping `uint32` — sufficient for ~272 years at 2s block times, and packs the three block number fields into a single storage slot alongside the addresses.

The entity hash is a two-part EIP-712 structured hash (see [entity-hash.md](entity-hash.md)):

```
coreHash   = hashStruct(CoreHash(entityKey, creator, createdAt, contentType, payload, attributes))
entityHash = hashStruct(EntityHash(coreHash, owner, updatedAt, expiresAt))
```

The two-part structure enables `extendEntity` and `changeOwner` to recompute `entityHash` from chain state alone — no database query needed.

### 2.3 Attributes

Each entity has zero or more attributes. Attributes enable rich queries.

```solidity
enum AttributeType { UINT, STRING, ENTITY_KEY }

struct Attribute {
    ShortString name;       // up to 31 UTF-8 bytes, packed into bytes32
    AttributeType valueType;
    bytes32 fixedValue;     // used for UINT (uint256) and ENTITY_KEY (bytes32)
    string  stringValue;    // used for STRING
}
```

**Constraints:**
- Attribute names must be unique within an entity — enforced by requiring the array to be sorted ascending by name. Duplicate names would fail the strict ordering check.
- Attributes must be sorted ascending by `name` before submission. The contract verifies ordering in O(n) rather than sorting on-chain.
- The attribute type system is deliberately minimal — these are the types that can be evaluated on-chain by the challenge game's predicate evaluator.
- Maximum attribute count per entity: `MAX_ATTRIBUTES` (32).
- Maximum string attribute value size: `MAX_STRING_ATTR_SIZE` (1KB).

---

## 3. Storage

### 3.1 Entity Commitment Map

```solidity
// entityKey => Entity
mapping(bytes32 => Entity) public entities;
```

Provides:
- O(1) lookup by entity key
- Membership proof via `eth_getProof` against the EVM state trie
- Non-membership proof (empty slot) via the same mechanism

### 3.2 Per-Owner Nonces

```solidity
mapping(address owner => uint32) public nonces;
```

Incremented on each entity creation. Enables deterministic, predictable entity key derivation client-side.

### 3.3 Change Set Hash

```solidity
// Per-block change set hash (reset each block)
bytes32 public currentBlockChangeSetHash;

// Cumulative hash over all blocks
bytes32 public cumulativeChangeSetHash;

// Last block number in which a mutation occurred
uint256 public lastMutationBlock;
```

The change set hash is accumulated as each operation is processed within a block:

```
currentBlockChangeSetHash = keccak256(abi.encodePacked(
    currentBlockChangeSetHash,
    mutationType,    // CREATE=0, UPDATE=1, EXTEND=2, DELETE=3, EXPIRE=4
    entityKey,
    entityHash       // new hash for create/update, previous hash for delete
))
```

At the start of a new block (detected by `block.number > lastMutationBlock`), the per-block hash is finalized into the cumulative hash before processing the first operation:

```
cumulativeChangeSetHash = keccak256(abi.encodePacked(
    cumulativeChangeSetHash,
    lastMutationBlock,
    currentBlockChangeSetHash
))
currentBlockChangeSetHash = bytes32(0)
lastMutationBlock = block.number
```

### 3.4 $GLM Token Reference

```solidity
IERC20 public immutable glmToken;
```

The $GLM token contract address, set at deployment. All entity storage payments are $GLM transfers via `transferFrom` — requires the user to have approved the EntityRegistry contract.

### 3.5 Pricing

```solidity
// Price per byte of payload per block of expiry duration
uint256 public pricePerBytePerBlock;
```

The pricing model ties $GLM cost to payload size and storage duration. The exact pricing formula and governance mechanism for updating it are out of scope for this spec — the contract must support a configurable pricing function that can be upgraded.

---

## 4. Operations

### 4.1 Create

Creates a new entity. Reverts if the entity key already exists and has not expired.

**Parameters:**

| Parameter | Type | Description |
|---|---|---|
| `payload` | `bytes` | Entity content (max 120KB) |
| `contentType` | `string` | MIME type of the payload |
| `attributes` | `Attribute[]` | Entity attributes, sorted ascending by name |
| `expiresAt` | `BlockNumber` | Block number at which entity expires. Must be > current block. |

**Behavior:**
1. Compute `nonce = nonces[msg.sender]` then increment `nonces[msg.sender]`
2. Compute `entityKey = keccak256(abi.encodePacked(block.chainid, address(this), msg.sender, nonce))`
3. Validate entity — revert with custom error if invalid (see §8)
4. Verify `expiresAt > currentBlock()`
5. Compute `coreHash` via EIP-712 `CoreHash` struct hash
6. Calculate $GLM cost based on payload size and expiry duration
7. Transfer $GLM from `msg.sender` to the contract via `transferFrom`
8. Store `Entity(msg.sender, msg.sender, currentBlock(), currentBlock(), expiresAt, coreHash)` in `entities[entityKey]`
9. Update change set hash with mutation type CREATE
10. Emit `EntityCreated` event

### 4.2 Update

Updates an existing entity's payload and/or attributes. Does not change owner or expiry.

**Parameters:**

| Parameter | Type | Description |
|---|---|---|
| `entityKey` | `bytes32` | The entity to update |
| `payload` | `bytes` | New entity content |
| `contentType` | `string` | New MIME type |
| `attributes` | `Attribute[]` | New entity attributes (full replacement, not partial), sorted ascending by name |

**Behavior:**
1. Verify `entities[entityKey]` exists and has not expired
2. Verify `msg.sender == entities[entityKey].owner`
3. Validate entity — revert with custom error if invalid (see §8)
4. Compute new `coreHash`
5. Calculate $GLM cost for size delta (if new payload is larger, charge for the difference × remaining blocks; if smaller, no refund)
6. Transfer $GLM if charge > 0
7. Update `entities[entityKey].coreHash` and `entities[entityKey].updatedAt`
8. Update change set hash with mutation type UPDATE
9. Emit `EntityUpdated` event

### 4.3 Extend

Extends an entity's expiry block. Does not change payload or attributes.

**Parameters:**

| Parameter | Type | Description |
|---|---|---|
| `entityKey` | `bytes32` | The entity to extend |
| `newExpiresAt` | `BlockNumber` | New expiry block. Must be > current expiry. |

**Behavior:**
1. Verify `entities[entityKey]` exists and has not expired
2. Verify `msg.sender == entities[entityKey].owner`
3. Verify `newExpiresAt > entities[entityKey].expiresAt`
4. Calculate $GLM cost for the additional duration × current payload size
5. Transfer $GLM
6. Update `entities[entityKey].expiresAt` and `entities[entityKey].updatedAt`
7. Update change set hash with mutation type EXTEND
8. Emit `EntityExtended` event

### 4.4 Delete

Removes an entity before its expiry. Owner-initiated.

**Parameters:**

| Parameter | Type | Description |
|---|---|---|
| `entityKey` | `bytes32` | The entity to delete |

**Behavior:**
1. Verify `entities[entityKey]` exists and has not expired
2. Verify `msg.sender == entities[entityKey].owner`
3. Remove `entities[entityKey]` from storage (zero out the mapping slot)
4. Update change set hash with mutation type DELETE
5. Emit `EntityDeleted` event
6. Optionally: calculate and refund unused $GLM for remaining expiry blocks (design decision — refunds add complexity and potential for gaming)

---

## 5. Batch API

The batch API allows multiple entity operations in a single transaction, amortizing base transaction gas across operations.

### 5.1 Operation Encoding

```solidity
enum OpType { CREATE, UPDATE, EXTEND, DELETE }

struct BatchOp {
    OpType      operationType;
    bytes32     entityKey;      // used for UPDATE, EXTEND, DELETE (ignored for CREATE)
    bytes       payload;        // used for CREATE, UPDATE
    string      contentType;    // used for CREATE, UPDATE
    Attribute[] attributes;     // used for CREATE, UPDATE
    BlockNumber expiresAt;      // used for CREATE, EXTEND
}
```

### 5.2 Batch Execute

```solidity
function executeBatch(BatchOp[] calldata ops) external
```

**Behavior:**
1. Iterate over `ops` in order
2. For each operation, execute the corresponding logic from §4 (create, update, extend, delete)
3. Each operation independently validates, charges $GLM, and updates the change set hash
4. If any operation reverts, the entire batch reverts (atomic)
5. Emit individual events per operation (not a single batch event) — the off-chain DB must see each mutation separately

**Constraints:**
- Maximum batch size: TBD (gas-bounded in practice, likely 50-200 operations depending on payload sizes)
- Operations within a batch are ordered — the change set hash accumulates them in submission order
- A batch may contain operations on the same entity (e.g., create then update) — they execute sequentially within the batch

---

## 6. Events

Events are the primary interface for the off-chain DB component. The DB derives its full state by processing these events from genesis.

### 6.1 Event Definitions

```solidity
event EntityCreated(
    bytes32     indexed entityKey,
    address     indexed owner,
    bytes32     entityHash,
    BlockNumber expiresAt,
    bytes       payload,
    string      contentType,
    Attribute[] attributes
);

event EntityUpdated(
    bytes32     indexed entityKey,
    address     indexed owner,
    bytes32     entityHash,
    bytes       payload,
    string      contentType,
    Attribute[] attributes
);

event EntityExtended(
    bytes32     indexed entityKey,
    address     indexed owner,
    bytes32     entityHash,
    BlockNumber previousExpiresAt,
    BlockNumber newExpiresAt
);

event EntityDeleted(
    bytes32 indexed entityKey,
    address indexed owner,
    bytes32 entityHash
);

event EntityExpired(
    bytes32     indexed entityKey,
    address     indexed owner,
    bytes32     entityHash,
    BlockNumber expiresAt
);

event ChangeSetHashFinalized(
    uint256 indexed blockNumber,
    bytes32 blockChangeSetHash,
    bytes32 cumulativeChangeSetHash
);
```

### 6.2 Design Rationale

- **Full payload in events:** The `EntityCreated` and `EntityUpdated` events include the full payload and attributes. This is the data path for the off-chain DB — it reconstructs entity state entirely from events without needing access to transaction calldata. At 120KB payloads, this is expensive in DA cost but architecturally clean. See [tech-stack-options.md §2.6](tech-stack-options.md) for the DA path alternative if gas economics require separating payload from events.
- **Indexed fields:** `entityKey` and `owner` are indexed for efficient filtering by the DB component. `entityHash` is not indexed — it changes on every update and is not a useful filter.
- **Individual events per operation:** Batch operations emit individual events, not a single batch event. The DB component processes events sequentially and must see each mutation as a discrete unit.
- **ChangeSetHashFinalized:** Emitted once per block when the first mutation of a new block triggers finalization of the previous block's change set hash. The DB component uses this to verify its independently computed change set hash matches the contract's.

---

## 7. Expiry Handling

Entity expiry is protocol-enforced but requires a trigger mechanism on-chain.

### 7.1 Lazy Expiry

Expired entities are not automatically removed from the contract's storage. Instead, expiry is enforced lazily:

- **On access:** Any operation that reads an entity checks `currentBlock() >= entity.expiresAt`. If expired, the entity is treated as non-existent.
- **On create with same key:** Not applicable — entity keys are derived from owner + nonce and are never reused.
- **Explicit cleanup:** An `expireEntity(bytes32 entityKey)` function allows anyone to trigger expiry removal for an entity past its expiry block. This emits the `EntityExpired` event and updates the change set hash, enabling the DB component to process the removal.

### 7.2 Explicit Cleanup

```solidity
function expireEntity(bytes32 entityKey) external
function expireEntities(bytes32[] calldata entityKeys) external
```

Callable by anyone (not just the owner). Reverts if the entity has not expired. No $GLM cost. Emits `EntityExpired` and updates the change set hash.

The batch variant allows efficient bulk cleanup. Sequencer nodes or dedicated cleanup bots are expected to call this periodically.

### 7.3 Off-Chain DB Expiry

The off-chain DB component independently tracks expiry and removes entities from its index at the expiry block. It does not wait for the on-chain `EntityExpired` event — expiry block numbers are deterministic and known in advance.

The `EntityExpired` event is the on-chain confirmation that the contract's state matches. If the on-chain cleanup is delayed (no one called `expireEntity`), the DB component's state is ahead of the contract's storage — but the change set hash will reconcile when the on-chain cleanup eventually occurs.

**Open question:** Should the change set hash include expiry-driven removals at the expiry block regardless of whether `expireEntity` was called? This would require the contract to process expiries deterministically at a specific block, which conflicts with the lazy expiry model. This is a critical design decision — see [engineering-tasks.md §1.4](engineering-tasks.md) for the full problem statement.

---

## 8. Access Control and Validation

### 8.1 Custom Errors

The contract uses custom errors throughout — not `require` with string messages. Custom errors are cheaper (4-byte selector vs full string in revert data) and carry typed parameters for debugging.

```solidity
error PayloadTooLarge(uint256 size, uint256 max);
error TooManyAttributes(uint256 count, uint256 max);
error StringAttributeTooLarge(ShortString name, uint256 size, uint256 max);
error AttributesNotSorted(ShortString name, ShortString previousName);
error NotOwner(bytes32 entityKey, address caller, address owner);
error EntityExpiredError(bytes32 entityKey, BlockNumber expiresAt);
error EntityNotFound(bytes32 entityKey);
error ExpiryNotExtended(BlockNumber newExpiresAt, BlockNumber currentExpiresAt);
error ExpiryInPast(BlockNumber expiresAt, BlockNumber currentBlock);
error InsufficientGLM(uint256 required, uint256 available);
```

### 8.2 Owner Validation

All mutation operations (update, extend, delete) require `msg.sender == entities[entityKey].owner`. Reverts with `NotOwner`. No delegation, no admin override, no multi-sig. Owner is immutable and set at creation.

### 8.3 Expiry Validation

All mutation operations verify `currentBlock() < entities[entityKey].expiresAt`. Operations on expired entities revert with `EntityExpiredError` (except explicit expiry cleanup).

### 8.4 $GLM Payment Validation

Create, update (if size increases), and extend operations require sufficient $GLM approval and balance. The contract calls `glmToken.transferFrom(msg.sender, address(this), amount)`. Insufficient balance or approval reverts with `InsufficientGLM`.

### 8.5 Entity Validation

Enforced by `validateEntity(payload, attributes)` called on create and update:
- `payload.length <= MAX_PAYLOAD_SIZE` — reverts with `PayloadTooLarge`
- `attributes.length <= MAX_ATTRIBUTES` — reverts with `TooManyAttributes`
- String attributes: `stringValue.length <= MAX_STRING_ATTR_SIZE` — reverts with `StringAttributeTooLarge`
- Attributes sorted ascending by name (strict) — reverts with `AttributesNotSorted` (also enforces uniqueness)

---

## 9. Code Organisation

The contract follows the solhint `ordering` rule:

```
1. Type declarations  (enum, struct)
2. Errors
3. Constants
4. State variables
5. Constructor
6. Functions, ordered by visibility then mutability:
   external > public > internal > private
   within each: pure > view > non-payable > payable
```

---

## 10. Constants and Configuration

```solidity
uint256 public constant MAX_PAYLOAD_SIZE     = 122880; // 120 KB
uint256 public constant MAX_ATTRIBUTES       = 32;
uint256 public constant MAX_STRING_ATTR_SIZE = 1024;   // 1 KB

// Mutation types for change set hash
uint8 public constant MUTATION_CREATE = 0;
uint8 public constant MUTATION_UPDATE = 1;
uint8 public constant MUTATION_EXTEND = 2;
uint8 public constant MUTATION_DELETE = 3;
uint8 public constant MUTATION_EXPIRE = 4;
```

---

## 11. Open Design Questions

These must be resolved before implementation:

1. **Expiry in change set hash:** Should expiry-driven removals be included in the change set hash at the expiry block deterministically, or only when `expireEntity` is called? Deterministic expiry produces cleaner DB ↔ contract consistency but requires the contract to have an expiry processing mechanism that runs at a specific block. See §7.3.

2. **$GLM refund on delete:** Should early deletion refund unused $GLM for remaining expiry blocks? Refunds are user-friendly but add complexity and potential gaming vectors (create with long expiry, delete immediately for near-full refund after extracting utility).

3. **$GLM refund on update (size reduction):** Should reducing payload size refund the cost difference? Same trade-offs as delete refunds.

4. **Pricing governance:** How is `pricePerBytePerBlock` updated? Options: owner-controlled, DAO governance, algorithmic (based on utilization). This affects decentralization properties.

5. **120KB payload in events vs. DA path:** At 120KB, emitting the full payload in an event log may be prohibitively expensive on some L2s. The alternative — emit only the hash in the event, post the payload to a DA layer separately — is architecturally clean but introduces a DA dependency for the DB component. This decision affects the event definitions in §6.

---

## 12. Upgrade Path

The EntityRegistry is intended to be deployed as a non-upgradeable contract for v1. The entity commitment map and change set hash are protocol-critical state — upgradeability introduces a trust assumption (who controls the proxy?) that conflicts with permissionless operation.

If the contract needs to evolve (e.g., new attribute types, changed pricing), a new version is deployed. Entity migration from v1 to v2 is handled at the application layer, not the contract layer.

**Rationale:** A non-upgradeable contract is easier to audit, has a smaller attack surface, and provides stronger guarantees to entity owners that the rules will not change after they have paid for storage.
