# Attribute Encoding Specification

Cross-language reference for computing attribute, core, and entity hashes. Every implementation — Solidity, Go, Rust, TypeScript, Python — must produce identical hashes for the same inputs.

---

## 1. Attribute Types

| valueType | Constant | Value encoding |
|---|---|---|
| 0 | ATTR_UINT | 32-byte big-endian uint256 |
| 1 | ATTR_STRING | Raw UTF-8 bytes |
| 2 | ATTR_ENTITY_KEY | 32 raw bytes (bytes32) |

---

## 2. Attribute Hash

Type string:
```
Attribute(string name,uint8 valueType,bytes value)
```

Typehash:
```
ATTRIBUTE_TYPEHASH = keccak256("Attribute(string name,uint8 valueType,bytes value)")
```

Encoding (EIP-712 `hashStruct`):
```
attributeHash = keccak256(abi.encode(
    ATTRIBUTE_TYPEHASH,
    keccak256(utf8_bytes(name)),
    valueType,
    keccak256(value_bytes)
))
```

Where `abi.encode` is ABI encoding with each field padded to 32 bytes, and `value_bytes` is the type-dependent encoding from §1.

### Worked example — UINT attribute

```
name        = "count"
valueType   = 0  (ATTR_UINT)
value       = uint256(42) as 32-byte big-endian
            = 0x000000000000000000000000000000000000000000000000000000000000002a

nameHash    = keccak256(0x636f756e74)   // keccak256("count")
valueHash   = keccak256(0x000000000000000000000000000000000000000000000000000000000000002a)

attributeHash = keccak256(abi.encode(ATTRIBUTE_TYPEHASH, nameHash, 0, valueHash))
```

### Worked example — STRING attribute

```
name        = "label"
valueType   = 1  (ATTR_STRING)
value       = 0x68656c6c6f   // "hello" as UTF-8

nameHash    = keccak256(0x6c6162656c)   // keccak256("label")
valueHash   = keccak256(0x68656c6c6f)   // keccak256("hello")

attributeHash = keccak256(abi.encode(ATTRIBUTE_TYPEHASH, nameHash, 1, valueHash))
```

---

## 3. Attribute Ordering

Attributes must be submitted in ascending order of `keccak256(utf8_bytes(name))`, interpreted as a uint256. This enforces:

- **Determinism** — identical attribute sets always produce the same hash regardless of original insertion order
- **Name uniqueness** — strict ascending order (no equal values) means no two attributes can share a name

Callers compute `keccak256(name)` for each attribute and sort by that value before submission. The contract validates strict ascending order during the hash pass.

Note: this is NOT lexicographic order. The attribute named `"apple"` may sort after `"zebra"` depending on their keccak256 hashes. The ordering is deterministic but not human-intuitive.

---

## 4. Attribute Chain Hash (Rolling Hash)

The attribute array is hashed using a rolling chain, starting from `bytes32(0)`:

```
chain₀ = bytes32(0)
chainᵢ = keccak256(chainᵢ₋₁ ++ attributeHash(attributes[i]))
attributesHash = chainₙ
```

Where `++` is byte concatenation (64 bytes: 32-byte chain + 32-byte attribute hash).

An empty attribute array produces `bytes32(0)`.

This follows the same pattern as the changeset hash chain (`chainOp`).

---

## 5. Core Hash

Type string:
```
CoreHash(bytes32 entityKey,address creator,uint32 createdAt,string contentType,bytes payload,bytes32 attributesHash)
```

Encoding:
```
coreHash = keccak256(abi.encode(
    CORE_HASH_TYPEHASH,
    entityKey,
    creator,
    createdAt,
    keccak256(utf8_bytes(contentType)),
    keccak256(payload),
    attributesHash
))
```

The `attributesHash` is the rolling chain result from §4. It is an opaque `bytes32` — CoreHash does not reference the Attribute type.

---

## 6. Entity Hash

Two-layer structure enabling partial recomputation:

```
coreHash    = hashStruct(CoreHash(...))          // immutable content
entityHash  = hashStruct(EntityHash(coreHash, owner, updatedAt, expiresAt))
finalHash   = EIP-712 domain separator wrapping of entityHash
```

Type string:
```
EntityHash(bytes32 coreHash,address owner,uint32 updatedAt,uint32 expiresAt)
```

Operations that change only mutable fields (extend expiry, transfer ownership) recompute `entityHash` from the stored `coreHash` without needing the original payload or attributes.

---

## 7. Value Encoding Reference

For non-Solidity implementations, the exact bytes to produce for each value type:

| Type | Input | Bytes to hash |
|---|---|---|
| ATTR_UINT (0) | `uint256` value | `abi.encode(value)` — left-pad to 32 bytes, big-endian |
| ATTR_STRING (1) | UTF-8 string | Raw bytes of the string, no padding, no length prefix |
| ATTR_ENTITY_KEY (2) | `bytes32` key | The 32 bytes as-is |

`abi.encode` for a single `uint256` or `bytes32` is simply the value as 32 bytes. There is no length prefix or offset — just the raw 32-byte word.
