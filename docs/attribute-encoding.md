# Attribute Encoding Specification

Cross-language reference for computing attribute, core, and entity hashes. Every implementation — Solidity, Go, Rust, TypeScript, Python — must produce identical hashes for the same inputs.

---

## 1. Attribute Name Encoding

Attribute names are `bytes32`: the UTF-8 string bytes left-aligned, zero-padded to 32 bytes. Maximum 32 ASCII characters.

```
"count" → 0x636f756e7400000000000000000000000000000000000000000000000000000000
           c o u n t  [zero-padded to 32 bytes]
```

Cross-language packing: `utf8_bytes(name).pad_right(32, 0x00)`.

No length byte. To recover the string, trim trailing zero bytes.

## 2. Attribute Value Types

| valueType | Constant | Value encoding |
|---|---|---|
| 0 | ATTR_UINT | 32-byte big-endian uint256 |
| 1 | ATTR_STRING | Raw UTF-8 bytes |
| 2 | ATTR_ENTITY_KEY | 32 raw bytes (bytes32) |

---

## 3. Attribute Hash

Type string:
```
Attribute(bytes32 name,uint8 valueType,bytes value)
```

Typehash:
```
ATTRIBUTE_TYPEHASH = keccak256("Attribute(bytes32 name,uint8 valueType,bytes value)")
```

Encoding (EIP-712 `hashStruct`):
```
attributeHash = keccak256(abi.encode(
    ATTRIBUTE_TYPEHASH,
    name,                // bytes32 — used directly, no hashing
    valueType,           // uint8
    keccak256(value)     // bytes — dynamic type, hashed per EIP-712
))
```

The `name` is a static `bytes32` type in the EIP-712 encoding — it goes into `abi.encode` directly with no `keccak256` wrapping. Only the `value` field is dynamic (`bytes`) and gets hashed.

### Worked example — UINT attribute

```
name        = 0x636f756e7400...00   ("count" packed as bytes32)
valueType   = 0                      (ATTR_UINT)
value       = 0x000000000000000000000000000000000000000000000000000000000000002a
              (uint256(42) as 32-byte big-endian)

attributeHash = keccak256(abi.encode(ATTRIBUTE_TYPEHASH, name, 0, keccak256(value)))
```

### Worked example — STRING attribute

```
name        = 0x6c6162656c00...00   ("label" packed as bytes32)
valueType   = 1                      (ATTR_STRING)
value       = 0x68656c6c6f          ("hello" as raw UTF-8 bytes)

attributeHash = keccak256(abi.encode(ATTRIBUTE_TYPEHASH, name, 1, keccak256(value)))
```

---

## 4. Attribute Ordering

Attributes must be submitted in strict ascending order of `name` (the packed `bytes32`), interpreted as a big-endian uint256. This enforces:

- **Determinism** — identical attribute sets always produce the same hash regardless of original insertion order
- **Name uniqueness** — strict ascending order (no equal values) means no two attributes can share a name

This is natural lexicographic order for left-aligned UTF-8 strings: `"aaa" < "bbb" < "count" < "label"`.

Callers sort by the packed `bytes32` name before submission. The contract validates strict ascending order during the hash pass at zero additional cost — the name is already loaded for the attribute hash.

---

## 5. Attribute Chain Hash (Rolling Hash)

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

## 6. Core Hash

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

The `attributesHash` is the rolling chain result from §5. It is an opaque `bytes32` — CoreHash does not reference the Attribute type.

---

## 7. Entity Hash

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

## 8. Value Encoding Reference

For non-Solidity implementations, the exact bytes to produce for each field:

| Field | Encoding |
|---|---|
| `name` (bytes32) | UTF-8 bytes, left-aligned, zero-padded to 32 bytes. Used directly in `abi.encode`. |
| ATTR_UINT value | `abi.encode(uint256)` — 32 bytes, big-endian. Then `keccak256`. |
| ATTR_STRING value | Raw UTF-8 bytes, no padding, no length prefix. Then `keccak256`. |
| ATTR_ENTITY_KEY value | 32 bytes as-is. Then `keccak256`. |

`abi.encode` for a single `uint256` or `bytes32` is simply the value as 32 bytes — no length prefix or offset.

### Design rationale — bytes32 name

The `name` field uses `bytes32` rather than `string` because:

- **No hashing required**: static EIP-712 type, goes directly into `abi.encode` — zero `keccak256` ops per attribute name
- **Efficient sorting**: single `bytes32` comparison gives natural lexicographic order on the packed UTF-8 — no need for byte-by-byte comparison or hash-based ordering
- **Cheap calldata**: fixed 32 bytes vs dynamic ABI string encoding (96+ bytes)
- **Cross-language simplicity**: `utf8_bytes.pad_right(32, 0x00)` — trivial in any language, no library dependency
- **Sufficient capacity**: 32 ASCII characters covers any reasonable attribute identifier
