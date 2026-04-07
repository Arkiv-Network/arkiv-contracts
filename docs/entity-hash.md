# ADR-PRF-002: Entity Hash

| Property | Value |
|----------|-------|
| **Status** | ⚠️ Proposal |
| **Level** | L3 (Implementation) |
| **Cluster** | PRF (Commitment/Proof) |
| **Created** | January 2026 |
| **Last Updated** | March 2026 |

## Context

ARKIV needs to hash entities for:
- Merkle tree leaves (entityStateRoot per [ADR-PRF-003](ADR-PRF-003.md))
- Verification (compare query results to chain)
- Integrity (detect tampering)

The hash structure must:
- Commit to all entity state
- Be computable without database queries
- Support efficient operations (extend, changeOwner)
- Be computable outside of smart contracts (e.g. clients verifying data returned by an Arkiv node)

## Decision

**Use EIP-712 structured hashing with a two-part structure separating core and mutable fields.**

EIP-712 is chosen over raw `abi.encode` because:
- Fully specified and language-agnostic — implementations exist in JS, Python, Rust, Go
- Domain separator natively prevents cross-chain and cross-contract hash collisions
- Standard tooling everywhere (viem, ethers.js, etc.) — no custom encoding logic needed
- Easier to audit — the pattern is widely understood

### EIP-712 Domain

```javascript
{
  name: "Arkiv EntityRegistry",
  version: "1",
  chainId: <uint256>,
  verifyingContract: <address>  // EntityRegistry contract address
}
```

### Type Definitions

```javascript
Attribute(
  bytes32 name,        // up to 31 UTF-8 bytes packed as ShortString
  uint8   valueType,   // 0=UINT, 1=STRING, 2=ENTITY_KEY
  bytes32 fixedValue,  // used for UINT and ENTITY_KEY
  string  stringValue  // used for STRING
)

CoreHash(
  bytes32     entityKey,
  address     creator,
  uint32      createdAt,
  string      contentType,
  bytes       payload,
  Attribute[] attributes   // sorted ascending by name
)

EntityHash(
  bytes32 coreHash,    // hashStruct(CoreHash)
  address owner,
  uint32  updatedAt,
  uint32  expiresAt
)
```

### Hash Computation

```javascript
// 1. Hash each attribute
attributeHash = hashStruct(Attribute(...))

// 2. coreHash — stable across extend/changeOwner operations
coreHash = hashStruct(CoreHash(
  entityKey, creator, createdAt, contentType, payload, attributes
))

// 3. entityHash — recomputable from chain state alone
entityHash = hashStruct(EntityHash(coreHash, owner, updatedAt, expiresAt))
```

EIP-712 handles encoding automatically:
- `string` and `bytes` fields → `keccak256` before encoding
- Nested structs → recursively hashed
- Arrays → `keccak256(concat(element hashes))`

### Field Categorization

| Category | Fields | Changed By |
|----------|--------|------------|
| **Core** (in coreHash) | entityKey, creator, createdAt, contentType, payload, attributes (sorted by name) | create, update only |
| **Mutable** (outside coreHash) | owner, updatedAt, expiresAt | Any operation |

### Why Two-Part Structure

| Operation | With Two-Part | With Single Hash |
|-----------|---------------|------------------|
| `extendEntity` | Recompute from coreHash + new expiresAt | Need full entity data |
| `changeOwner` | Recompute from coreHash + new owner | Need full entity data |
| Chain state only (no DB) | ✅ Yes | ❌ No |

This enables computing `entityHash` from **chain state alone** — no database query needed.

## Entity State

The chain stores **Entity State** — a mapping from entity key to metadata:

```
entityKey → { coreHash, owner, updatedAt, expiresAt }
```

~96 bytes per entity (32 + 20 + 4 + 4 + padding), sufficient to compute entityHash for any operation.

### Analogy to Ethereum Account State

| Ethereum Account State | ARKIV Entity State |
|------------------------|--------------------|
| `address` | `entityKey` |
| `nonce` | (implicit in tx ordering) |
| `balance` | — |
| `codeHash` | `coreHash` (immutable content commitment) |
| `storageRoot` | — |
| — | `owner` |
| — | `updatedAt` |
| — | `expiresAt` |

Just as Ethereum's account state enables computing `stateRoot` without accessing contract storage, ARKIV's Entity State enables computing `entityHash` without database queries.

## Encoding Rules

| Rule | Specification |
|------|---------------|
| Hash function | keccak256 |
| Encoding scheme | EIP-712 typed structured data |
| Integer encoding | Fixed-width, big-endian (EIP-712 default) |
| String encoding | UTF-8 |
| Attribute ordering | Single array sorted ascending by name (lexicographic) |
| Empty values | Explicit encoding (not omitted) |

### Attribute Structure

Each attribute has a name (up to 31 UTF-8 bytes) and a typed value. Three value types are supported:

| Type | `valueType` | Value field | Encoding |
|------|-------------|-------------|----------|
| `UINT` | 0 | `fixedValue` | `bytes32` (uint256, big-endian) |
| `STRING` | 1 | `stringValue` | `string` (UTF-8), hashed by EIP-712 |
| `ENTITY_KEY` | 2 | `fixedValue` | `bytes32` |

Attribute names are unique within an entity. Duplicate names in a single operation are invalid.

### Client Verification Example (TypeScript/viem)

```typescript
const entityHash = hashTypedData({
  domain: {
    name: "Arkiv EntityRegistry",
    version: "1",
    chainId,
    verifyingContract: registryAddress,
  },
  types: { EntityHash, CoreHash, Attribute },
  primaryType: "EntityHash",
  message: { coreHash, owner, updatedAt, expiresAt },
})
```

## Security Considerations

| Aspect | Analysis |
|--------|----------|
| **Assumption** | Encoding is deterministic across all implementations |
| **Assumption** | keccak256 is collision-resistant |
| **Mitigates** | Cross-chain hash collisions — domain separator binds hash to chainId + contract address |
| **Mitigates** | Hash manipulation — all fields contribute to hash |
| **Mitigates** | Selective field omission — explicit encoding of empty values |
| **Critical** | Non-deterministic encoding breaks consensus — must be tested extensively across implementations |
| **Does NOT mitigate** | Payload content attacks — hash doesn't validate payload semantics |

## Implementation Status

| Component | Status |
|-----------|--------|
| Two-part structure | ⚠️ Concept documented, implementation unclear |
| EIP-712 type definitions | ⚠️ Defined in this ADR, not yet implemented |
| coreHash computation | ⚠️ Needs verification |
| Entity State | ⚠️ Partially implemented |

## Validation Criteria

- [ ] Verify code implements two-part EIP-712 structure
- [ ] Test: extendEntity doesn't need DB query
- [ ] Test: changeOwner doesn't need DB query
- [ ] Test: hash computation deterministic across Solidity and TypeScript implementations
- [ ] Test: domain separator correctly binds hash to chainId and contract address

## Related Decisions

- [ADR-API-001](../API/ADR-API-001.md): Entity Data Model — what gets hashed
- [ADR-PRF-001](ADR-PRF-001.md): Entity Key Derivation — key is part of hash
- [ADR-PRF-003](ADR-PRF-003.md): entityStateRoot — uses entityHash as MPT leaf values
- [ADR-EXE-003](../EXE/ADR-EXE-003.md): Deterministic State Transitions — encoding

---

**Changelog**
- 2026-03-23: Adopted EIP-712 structured hashing; updated attribute model to single sorted array with dual-field struct; renamed initialOwner to creator
- 2026-01-30: Updated references for new ADR numbering
- 2026-01-25: Extracted to formal ADR
- 2026-XX-XX: Design documented
