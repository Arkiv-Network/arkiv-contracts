# Value128: Fixed-Size Attribute Value Encoding

| Property | Value |
|----------|-------|
| **Status** | Ideation |
| **Depends on** | [ADR-API-004](ADR-API-004.md) (String Field Encoding), `src/Ident32.sol`, `src/Mime128.sol` |
| **Created** | April 2026 |

## Problem

The `Attribute` struct currently uses `bytes value` — a dynamic byte array with no fixed size:

```solidity
struct Attribute {
    Ident32 name;
    uint8 valueType;
    bytes value;      // ← dynamic, variable length
}
```

Three value types are supported:
- `ATTR_UINT` (0): 32 bytes (abi-encoded uint256)
- `ATTR_STRING` (1): up to 1024 bytes
- `ATTR_ENTITY_KEY` (2): 32 bytes (abi-encoded bytes32)

Per ADR-API-004, string attribute values should be capped at **128 bytes** (not 1024), and the protocol treats them as **opaque byte arrays** with byte-level ordering for predicates and sorting.

Replacing `bytes value` with `bytes32[4]` (128 bytes, fixed) would:
1. Unify all three value types into a single fixed-size representation
2. Eliminate dynamic ABI encoding overhead (length prefix, padding, pointer indirection)
3. Make the `Attribute` struct fully fixed-size — simpler calldata layout, predictable gas
4. Align with the `Mime128` / `Ident32` pattern of fixed-size validated types

The challenge is that `bytes32[4]` must encode three semantically different value types, each with different encoding rules.

## The three encodings

### 1. ATTR_UINT — numeric values

**In `bytes32[4]`:** The uint256 occupies `data[0]` as a right-aligned `bytes32`. Slots `data[1..3]` are zero.

```
data[0]: 0x000000000000000000000000000000000000000000000000000000000000002a  (42)
data[1]: 0x0000000000000000000000000000000000000000000000000000000000000000
data[2]: 0x0000000000000000000000000000000000000000000000000000000000000000
data[3]: 0x0000000000000000000000000000000000000000000000000000000000000000
```

**Encoding rule:** `data[0] = bytes32(value)`. Standard ABI uint256 layout — right-aligned, big-endian.

**Sorting:** Byte-level comparison on `data[0]` matches numeric ordering because big-endian uint256 preserves magnitude order under lexicographic comparison.

### 2. ATTR_STRING — opaque byte arrays (NFC UTF-8 by convention)

**In `bytes32[4]`:** Left-aligned, zero-padded — identical to `Mime128` and `Ident32` packing.

```
"hello world" (11 bytes):
data[0]: 0x68656c6c6f20776f726c640000000000000000000000000000000000000000
data[1..3]: 0x00...
```

**Encoding rule:** Left-aligned, zero-padded. Same as `encodeMime128` byte packing.

**Sorting:** Byte-level comparison across all 4 words matches lexicographic string ordering. Shorter strings sort before longer strings that share the same prefix (`"abc" < "abcd"`).

### 3. ATTR_ENTITY_KEY — cross-references

**In `bytes32[4]`:** `data[0]` holds the entity key. Slots `data[1..3]` are zero. Identical layout to ATTR_UINT.

**Encoding rule:** `data[0] = entityKey`.

## Encoding summary

| Type | `data[0]` | `data[1..3]` | Alignment | Sort semantics |
|---|---|---|---|---|
| `ATTR_UINT` | `bytes32(uint256)` | zero | Right-aligned | Numeric (big-endian) |
| `ATTR_STRING` | First 32 bytes of string | Continuation + zero padding | Left-aligned | Lexicographic (byte-level) |
| `ATTR_ENTITY_KEY` | Entity key hash | zero | N/A (full word) | Byte-level |

The `valueType` discriminator remains necessary — it distinguishes right-aligned (uint/key) from left-aligned (string) encoding, and prevents cross-type collisions in hash computation.

## Validation

On-chain validation of the value blob is **not necessary**. The `bytes32[4]` is opaque — encoding correctness is the caller's responsibility and is enforced by SDKs. The contract's role is:

1. Hash the value deterministically (always `keccak256(abi.encode(v[0], v[1], v[2], v[3]))`)
2. Include `valueType` in the hash to prevent cross-type collisions
3. Accept whatever bytes the caller provides

This matches ADR-API-004's position that string values are opaque byte arrays with no protocol-level encoding validation. The same principle extends to uint and entity key values — a malformed uint that uses all 4 words "wrong" still hashes deterministically. Off-chain indexers interpret the bytes according to `valueType`; the contract just commits to them.

## Extended type system

The fixed `bytes32[4]` container can support value types beyond the current three. The `valueType` discriminator is a `uint8` — 256 possible types. Potential additions:

### Variable-width integers

| Type | Encoding | Range | Use case |
|---|---|---|---|
| `ATTR_UINT8` | `data[0] = bytes32(uint256(value))` | 0–255 | Enum-like fields, small counters |
| `ATTR_UINT16` | same | 0–65,535 | Years, port numbers |
| `ATTR_UINT32` | same | 0–4.2B | Timestamps, IPv4 |
| `ATTR_UINT64` | same | 0–1.8×10¹⁹ | Balances, large counters |
| `ATTR_UINT128` | `data[0..1]` (first 16 bytes of data[0], or split across two words) | 0–3.4×10³⁸ | Token amounts, UUIDs |
| `ATTR_UINT256` | `data[0]` (full word) | Full uint256 | Hashes, large numerics |

All integer types use the same right-aligned big-endian encoding in `data[0]` — the width only affects **off-chain interpretation** (range validation, display). On-chain, the hash is identical regardless of declared width. The `valueType` tag lets indexers enforce range constraints and choose appropriate storage/sort strategies.

A `ATTR_UINT128` that spans two words raises a design question: should the encoding use `data[0]` high 16 bytes + `data[1]` (split across words), or pack into `data[0]` right-aligned as a 128-bit value within a 256-bit word? Right-aligned in `data[0]` is simpler and preserves the single-word pattern for values ≤ 256 bits.

### Boolean

| Type | Encoding | Values |
|---|---|---|
| `ATTR_BOOL` | `data[0] = bytes32(uint256(0 or 1))` | `0` = false, `1` = true |

Trivial to add. Same right-aligned encoding. Off-chain indexers treat `0` as false, non-zero as true (or strictly `1`).

### Address

| Type | Encoding |
|---|---|
| `ATTR_ADDRESS` | `data[0] = bytes32(uint256(uint160(addr)))` |

Right-aligned, same as Solidity's native `abi.encode(address)`. Useful for owner references, linked accounts.

### Bytes32 (raw hash / identifier)

Already covered by `ATTR_ENTITY_KEY`, but a generic `ATTR_BYTES32` type could represent arbitrary 32-byte values without the entity-key semantic implication.

### Signed integers

| Type | Encoding |
|---|---|
| `ATTR_INT256` | `data[0] = bytes32(uint256(int256(value)))` — two's complement |

Byte-level sorting does **not** match numeric ordering for signed integers (negative values have high bits set, sorting after positive values). Off-chain indexers must sign-extend for correct comparison. This is a known trade-off — the protocol provides deterministic byte ordering, not semantically correct numeric ordering for signed types.

### Fixed-point / decimal

Could be represented as a scaled integer (`ATTR_UINT` with an implicit decimal point at a fixed position, e.g., 18 decimals). No new encoding needed — the `valueType` tag tells indexers how to interpret the uint.

## EIP-712 hash encoding

**Current:** `keccak256(attr.value)` — hashes the dynamic bytes.

**With `bytes32[4]`:** `keccak256(abi.encode(value[0], value[1], value[2], value[3]))` — hashes the four words. Same pattern as `Mime128` content type hashing.

The `ATTRIBUTE_TYPEHASH` changes from:
```
"Attribute(bytes32 name,uint8 valueType,bytes value)"
```
to:
```
"Attribute(bytes32 name,uint8 valueType,bytes32[4] value)"
```

## Collision resistance

The `valueType` discriminator is included in the EIP-712 hash:

```solidity
keccak256(abi.encode(ATTRIBUTE_TYPEHASH, name, valueType, keccak256(abi.encode(v[0], v[1], v[2], v[3]))))
```

This prevents cross-type collisions: a uint256 whose bytes happen to match a left-aligned string encoding will produce a different hash because `valueType` differs. Adding new types (ATTR_BOOL, ATTR_ADDRESS, etc.) automatically gets collision resistance from the existing discriminator — no changes to the hash structure needed.

## Struct layout change

```solidity
// Before — dynamic
struct Attribute {
    Ident32 name;       // 1 word
    uint8 valueType;    // 1 byte (padded to 1 word)
    bytes value;        // dynamic — pointer + length + data
}

// After — fully fixed
struct Attribute {
    Ident32 name;       // 1 word
    uint8 valueType;    // 1 byte (padded to 1 word)
    bytes32[4] value;   // 4 words, inline
}
```

The struct becomes fully fixed-size: 6 words in calldata. No pointer indirection, no length prefix, no dynamic ABI encoding.

## Whether to wrap in a struct

**Recommendation: bare `bytes32[4]`.** Unlike `Mime128` (single encoding, structural validation) or `Ident32` (single encoding, charset validation), attribute values have multiple encodings selected by `valueType`. A wrapper struct adds ceremony without preventing misuse — you'd still need to construct the `bytes32[4]` differently per type. The `valueType` field already provides the semantic tag.

## Gas impact

| Operation | Current (`bytes`) | Proposed (`bytes32[4]`) |
|---|---|---|
| ABI decode per attribute | Variable (offset + length + data) | Fixed (4 words inline) |
| Hash computation | `keccak256(attr.value)` — variable length | `keccak256(abi.encode(v[0],v[1],v[2],v[3]))` — always 128 bytes |
| Validation | Length checks per type | None (opaque) |

The hash computation becomes **constant cost** regardless of value content — always hashing 128 bytes. Slightly more expensive for 32-byte values (currently hashing 32 bytes), but eliminates variable gas and makes batch operations predictable.

`MAX_STRING_ATTR_SIZE` (currently 1024) becomes redundant — the fixed `bytes32[4]` enforces the 128-byte cap structurally. The constant and its length check can be deleted.

## Decisions

| Question | Decision | Rationale |
|---|---|---|
| Allow empty values? | **Yes** | All-zero `bytes32[4]` is valid. Attribute presence in the array is the signal; the value can be a zero/empty sentinel. |
| Allow zero uint? | **Yes** | Zero is a valid numeric value. |
| Remove `MAX_STRING_ATTR_SIZE`? | **Yes** | Redundant — 128-byte cap is structural. |
| On-chain charset validation for strings? | **No** | Opaque bytes per ADR-API-004. Would need performant 128-byte UTF-8 validation to reconsider — not justified today. |
| On-chain value validation? | **No** | Encoding correctness is the caller/SDK's responsibility. The contract hashes deterministically regardless of content. |
