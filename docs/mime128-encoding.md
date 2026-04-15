# Mime128: Fixed-Size MIME Type Encoding

| Property | Value |
|----------|-------|
| **Status** | Implementation |
| **Source** | `src/Mime128.sol` |
| **Depends on** | [ADR-API-004](ADR-API-004.md) (String Field Encoding) |
| **Created** | April 2026 |

## Problem

Entity operations include a `contentType` field that identifies the payload format. This field is hashed into the entity's EIP-712 core hash and stored on-chain. The protocol needs to:

1. Validate content types at the contract boundary — reject malformed or ambiguous values before they enter the hash chain
2. Represent content types in a fixed-size type compatible with EIP-712 structured hashing
3. Enforce determinism — the same logical content type must always produce the same hash, across contracts, SDKs, and chains

Dynamic `string` fails on all three counts. It has no built-in validation, its EIP-712 encoding requires an extra `keccak256` indirection, and case variation (`Application/JSON` vs `application/json`) silently produces different hashes for the same logical type. No existing on-chain library addresses this.

## Design

### Fixed-size representation: `bytes32[4]`

A MIME type with parameters (e.g., `text/plain; charset=utf-8`) fits comfortably within 128 bytes. The `Mime128` struct wraps `bytes32[4]` — four EVM words, left-aligned and zero-padded.

```solidity
struct Mime128 {
    bytes32[4] data;
}
```

**Why a struct, not a raw `bytes32[4]`?** Compile-time type safety. A bare `bytes32[4]` is indistinguishable from any other four-word array. The struct prevents accidental misuse — passing an attribute hash where a content type is expected — at zero runtime cost. The EIP-712 typehash uses the underlying `bytes32[4]` directly, per the project convention of keeping struct wrappers transparent to the hashing layer.

**Why 128 bytes?** MIME types without parameters rarely exceed 30 bytes (`application/octet-stream` is 24). Parameters push this further — `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` is 65 bytes, and adding `; charset=utf-8` reaches 83. 128 bytes (4 EVM words) covers all practical MIME types with parameters while keeping storage and calldata costs bounded. A single `bytes32` (32 bytes) handles bare types but cannot accommodate parameters; `bytes32[4]` covers both.

**Why not a dynamic `string`?** Three reasons:
- **Gas**: dynamic strings require length-prefixed memory allocation, ABI decoding overhead, and an extra `keccak256` call for EIP-712 encoding. A fixed `bytes32[4]` is four consecutive words in calldata — no allocation, no indirection.
- **Determinism**: strings permit case variation and trailing whitespace that produce different hashes for semantically identical types. Fixed-size encoding with validation eliminates this class of bugs.
- **Type safety**: a `string` is structurally identical to any other string. A `Mime128` is a distinct type at compile time.

### Charset: lowercase printable ASCII

All bytes must be printable ASCII (`0x20`–`0x7E`) with uppercase `A-Z` (`0x41`–`0x5A`) rejected. This is enforced per the decisions in [ADR-API-004](ADR-API-004.md) — the same charset applies to attribute names and content types.

Lowercase-only eliminates case ambiguity. RFC 2045 specifies that MIME types are case-insensitive, which means `text/plain` and `Text/Plain` are semantically equivalent — but they hash differently. By rejecting uppercase at the contract boundary, the protocol guarantees that only one canonical byte sequence exists for each logical type.

### Validation: RFC 2045 state machine

Charset alone is insufficient. `;;;===` passes a lowercase printable ASCII check but is not a valid MIME type. The validator enforces the structural grammar of RFC 2045 in a single pass using a five-state machine:

```
TYPE ──token──→ TYPE        PNAME ──token──→ PNAME
     ──  /   ──→ SUBTYPE          ──  =   ──→ PVALUE

SUBTYPE ──token──→ SUBTYPE   PVALUE ──token──→ PVALUE
        ──  ;   ──→ OWS             ──  ;   ──→ OWS
        ──  \0  ──→ END             ──  \0  ──→ END

OWS ──  ' ' ──→ OWS
    ──token──→ PNAME
```

Each state accepts either token characters (via a 256-bit bitmap lookup) or a specific structural character (`/`, `;`, `=`, space) that triggers the transition. The structural characters are valid *only* in the state where they cause a transition — a `/` in a parameter value is rejected, a space anywhere except after `;` is rejected.

Every segment (type, subtype, parameter name, parameter value) must be non-empty. The content must end in either `SUBTYPE` or `PVALUE` with at least one token character consumed. This means:

- `text/plain` — valid (TYPE → SUBTYPE → END)
- `text/plain; charset=utf-8` — valid (TYPE → SUBTYPE → OWS → PNAME → PVALUE → END)
- `text/` — invalid (empty subtype)
- `text/plain;` — invalid (incomplete, dangling semicolon)
- `text/plain; =utf-8` — invalid (empty parameter name)
- `/plain` — invalid (empty type)

### Token charset bitmap

The token charset is defined by RFC 2045 as printable ASCII minus SPACE, CTLs, and tspecials (`"`, `(`, `)`, `,`, `/`, `:`, `;`, `<`, `=`, `>`, `?`, `@`, `[`, `\`, `]`). Combined with the lowercase-only constraint, this is encoded as a compile-time `uint256` constant:

```solidity
uint256 constant MIME_TOKEN = LOWER_PRINTABLE_ASCII
    & ~uint256(
        (1 << 0x20) | (1 << 0x22) | (1 << 0x28) | (1 << 0x29)
        | (1 << 0x2C) | (1 << 0x2F) | (1 << 0x3A) | (1 << 0x3B)
        | (1 << 0x3C) | (1 << 0x3D) | (1 << 0x3E) | (1 << 0x3F)
        | (1 << 0x40) | (1 << 0x5B) | (1 << 0x5C) | (1 << 0x5D)
    );
```

Validation of a byte `b` against this bitmap is `(MIME_TOKEN >> b) & 1` — a shift and a mask. The constant is computed at compile time and costs nothing to load.

### Gas cost

The validator does one bitmap lookup and one state transition per byte. For typical MIME types:

| Content type | Bytes | Approximate gas |
|---|---|---|
| `text/plain` | 10 | ~200 |
| `application/json` | 16 | ~320 |
| `text/plain; charset=utf-8` | 25 | ~500 |

These figures are for the raw validation loop in pure Solidity. The overhead is negligible relative to any operation that stores the result (a cold `SSTORE` alone costs 20,000 gas).

#### Assembly optimization opportunity

The current implementation uses Solidity's `word[j]` indexing and nested `for` loops with `i / 32` and `i % 32` arithmetic. The compiler generates bounds checks, stack management, and division opcodes that are unnecessary when iterating a known-size `bytes32[4]`. An inline assembly rewrite would eliminate several sources of overhead:

| Source | Solidity cost | Assembly cost | Saving |
|---|---|---|---|
| Byte extraction (`word[j]`) | ~8 gas (bounds check + `BYTE`) | 3 gas (`BYTE` opcode) | ~5 gas/byte |
| Loop index division/modulo | ~10 gas (`DIV` + `MOD` per byte) | 0 (flat counter or unrolled) | ~10 gas/byte |
| State variable stack management | ~6 gas (repeated `MLOAD`/`MSTORE`) | 3 gas (register in stack) | ~3 gas/byte |
| Branch for zero check + bitmap | ~16 gas (Solidity conditionals) | ~10 gas (raw `JUMPI`) | ~6 gas/byte |

Estimated per-byte cost drops from ~20 gas (Solidity) to ~8 gas (assembly), roughly a 2.5x improvement:

| Content type | Bytes | Solidity (current) | Assembly (estimated) |
|---|---|---|---|
| `text/plain` | 10 | ~200 gas | ~80 gas |
| `application/json` | 16 | ~320 gas | ~130 gas |
| `text/plain; charset=utf-8` | 25 | ~500 gas | ~200 gas |

The assembly version would process one `bytes32` word at a time — load the word once (`CALLDATALOAD`, 3 gas), then extract 32 bytes via the `BYTE` opcode without any memory operations. The state machine logic stays identical; only the byte iteration and extraction change. The bitmap constant loads once at function entry and stays on the stack for the entire loop.

Whether this optimization is worth the auditability trade-off depends on call frequency. For a registration function called infrequently, the Solidity implementation is sufficient. For validation on every `CREATE`/`UPDATE` operation, the assembly version may be justified.

### Hashing

The lookup key for a `Mime128` is `keccak256(abi.encode(data[0], data[1], data[2], data[3]))`. This encodes each `bytes32` word as a 32-byte ABI slot and hashes the 128-byte result. The same encoding is used for EIP-712 structured hashing — the typehash references `bytes32[4]` directly, not a nested struct type.

## Prior art

No existing standard or library provides fixed-size MIME type encoding with structural validation:

- **ERC drafts** (NFT-Standards-WG content type): store MIME as `string` — no fixed-size encoding, no validation
- **ONCHFS (fxhash)**: HPACK-compressed HTTP headers — compact but variable-length, high complexity
- **OpenZeppelin ShortStrings**: 31-byte strings in `bytes32` — right size for bare types but no validation and cannot accommodate parameters
- **Bitcoin Ordinals**: raw ASCII in taproot scripts — no fixed-size encoding
- **Arweave tags**: base64url string pairs — no fixed-size encoding

The `Mime128` approach is, to our knowledge, novel: a fixed-size EVM-native type with single-pass RFC 2045 structural validation via a compile-time bitmap.

## Functions

| Function | Purpose |
|---|---|
| `encodeMime128(string memory)` | String → `Mime128`. Left-aligned, zero-padded. Reverts if empty or >128 bytes. |
| `decodeMime128(Mime128 memory)` | `Mime128` → string. Strips trailing zeros. |
| `validateMime128(Mime128 calldata)` | Structural + charset validation. Returns byte length. Reverts on invalid. |
| `mime128Hash(Mime128 calldata)` | Lookup key from calldata. |
| `mime128HashM(Mime128 memory)` | Lookup key from memory. |

## Open questions

- **Quoted string parameter values**: RFC 2045 allows `; charset="utf-8"` with quoted values. The current implementation only accepts token characters in parameter values. Quoted strings could be added as a sixth state (`S_QUOTED`) if needed — the state machine extends naturally.
- **Multiple parameters**: Supported. The `;` transition from `PVALUE` loops back to `OWS`, allowing `type/subtype; a=b; c=d`.
- **Integration with EntityRegistry**: `Mime128` is designed to replace the `string contentType` field in the `Operation` struct. This is a separate change that will update the `CORE_HASH_TYPEHASH` from `string contentType` to `bytes32[4] contentType`.
