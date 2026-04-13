# Ident32: Validated bytes32 Identifiers

| Property | Value |
|----------|-------|
| **Status** | Design |
| **Source** | `src/Ident32.sol` (to be created) |
| **Depends on** | [ADR-API-004](ADR-API-004.md) (String Field Encoding) |
| **Created** | April 2026 |

## Problem

Attribute names (`attr.name` in the `Attribute` struct) are `bytes32` values that currently receive no charset validation. The `attributeHash` function in `EntityHashing.sol` enforces sorted order and uniqueness, but accepts any 32-byte value — including uppercase, control characters, or arbitrary binary data.

This creates three problems:

1. **Case ambiguity**: `"Count"` and `"count"` are different `bytes32` values that hash differently. Two entities with semantically identical attributes produce different core hashes. The off-chain indexer must either reject one or treat them as distinct, with no protocol-level guidance.

2. **Non-determinism across SDKs**: A JavaScript SDK that lowercases attribute names and a Python SDK that doesn't will produce incompatible entities. The bug is silent — both produce valid transactions that the contract accepts.

3. **Garbage names**: Binary data, control characters, or emoji in attribute names pass validation today. This pollutes the index namespace and makes debugging harder.

Per [ADR-API-004](ADR-API-004.md), attribute names are **identifiers** — lowercase ASCII, maximum 32 bytes.

## Design

### Type

The attribute name stays as `bytes32` in the `Attribute` struct — no wrapper struct. Attribute names are already packed as left-aligned, zero-padded `bytes32` values throughout the codebase. Introducing a wrapper struct would change the `Attribute` struct layout, the EIP-712 `ATTRIBUTE_TYPEHASH`, and every test that constructs attributes. The cost exceeds the benefit for a field that is always a single word.

Instead, validation is a free function that operates on a bare `bytes32`:

```solidity
function validateIdent32(bytes32 value) pure returns (uint256 len);
```

### Charset

Attribute names are identifiers, not free-form text. The charset should be restrictive enough to prevent ambiguity while permitting readable, conventional naming patterns. Three options considered:

| Option | Valid chars | Example names | Allows |
|---|---|---|---|
| **A. `LOWER_PRINTABLE_ASCII`** | 0x20–0x7E minus uppercase | `content.length`, `a=b`, `x;y` | Space, `;`, `=`, `@`, `"`, etc. |
| **B. `MIME_TOKEN`** | RFC 2045 token chars, lowercase | `content.length`, `x-custom`, `tag!` | `.`, `-`, `_`, `!`, `#`, `%`, `+`, `^`, `'`, `*`, `` ` ``, `{`, `\|`, `}`, `~` |
| **C. Identifier charset** (recommended) | `a-z 0-9 . - _` | `content.length`, `x-custom`, `tag_v2` | Only the three separators that appear in real-world identifier conventions |

**Option A is too broad.** Characters like `;`, `=`, `@`, `"`, and space have no business in an identifier. They create parsing ambiguity in query languages, log output, and URL parameters. An attribute named `a=b` or `key;value` would be valid, which is confusing.

**Option B is narrower but still noisy.** MIME token chars include `!`, `#`, `%`, `'`, `*`, `^`, `` ` ``, `{`, `|`, `}`, `~` — characters that are technically allowed but never appear in real identifier conventions. Permitting them adds no practical value while making the namespace harder to reason about.

**Option C is the tightest useful set.** Lowercase alphanumeric plus three separators covers every conventional naming pattern:

| Pattern | Example | Separator |
|---|---|---|
| Flat | `count`, `status` | none |
| Dotted namespace | `content.length`, `http.status` | `.` |
| Kebab-case | `x-custom`, `created-at` | `-` |
| Snake-case | `tag_v2`, `file_size` | `_` |

No other separator carries its weight. `/` implies hierarchy (use dotted namespace instead), `:` implies key-value (confusing for a field that IS a key), and everything else is noise.

The bitmap for option C:

```
IDENT_CHARSET:
  a-z  (0x61–0x7A)  — 26 chars
  0-9  (0x30–0x39)  — 10 chars
  .    (0x2E)        — dotted namespace
  -    (0x2D)        — kebab-case
  _    (0x5F)        — snake_case
```

This is a new bitmap defined in `Ident32.sol`, not shared from `Mime128.sol`. The charsets serve different purposes — MIME tokens follow an RFC, identifiers follow naming conventions — and coupling them would be a false economy.

### Validation rules

1. **Non-empty**: at least one non-zero byte. Reverts with `Ident32Empty()`.
2. **Leading byte**: byte 0 must be `a-z`. Digits and separators are not valid as a leading character — `123count`, `.hidden`, `-flag`, `_private` are rejected. Reverts with `Ident32InvalidByte(0, value)`.
3. **Charset**: every subsequent non-zero byte must be in `IDENT_CHARSET` (`a-z`, `0-9`, `.`, `-`, `_`). Reverts with `Ident32InvalidByte(position, value)`.
4. **Left-aligned**: once a zero byte is encountered, all remaining bytes must also be zero (no embedded nulls). Reverts with `Ident32InvalidByte(position, 0x00)`.
5. **Returns length**: the number of non-zero bytes (1–32).

The leading-byte check is a single comparison before the loop — ~6 gas overhead.

No state machine needed — attribute names have no internal structure. A single linear scan suffices.

### Integration point

Validation is called in `EntityHashing.attributeHash()`, the existing single-pass function that already validates sort order, uniqueness, value types, and value lengths. Adding `validateIdent32(attr.name)` at the top of this function means every attribute name in every entity operation is validated — CREATE, UPDATE, and any future operation that includes attributes.

```solidity
function attributeHash(bytes32 prevName, bytes32 chain, Attribute calldata attr)
    internal
    pure
    returns (bytes32, bytes32)
{
    validateIdent32(attr.name);       // ← new
    if (attr.name <= prevName) revert AttributesNotSorted();
    // ... rest unchanged
}
```

This placement means validation runs before the sort check, producing clearer errors — "invalid byte at position 3" rather than a misleading "not sorted" when the real problem is an uppercase name.

### Gas cost

Single `bytes32` — 32 bytes maximum, one word:

| Operation | Gas |
|---|---|
| Leading byte check | ~6 gas |
| Bitmap check per byte | ~9 gas (shift + mask + branch) |
| Zero-byte tail check | ~3 gas/byte |
| Typical 5–10 char name | ~50–100 gas |
| Maximum 32 chars | ~320 gas |

Attribute hashing already costs ~500 gas per attribute (abi.encode + keccak256). Validation adds ~15–20% overhead per attribute. For a typical entity with 3–5 attributes, total added cost is 150–500 gas — negligible relative to the calldata and storage costs of the operation.

### Functions

| Function | Signature | Purpose |
|---|---|---|
| `validateIdent32` | `(bytes32) pure returns (uint256 len)` | Charset + leading byte + non-empty + no embedded nulls. Returns length. |
| `encodeIdent32` | `(string memory) pure returns (bytes32)` | String → left-aligned bytes32. Reverts if empty or >32 bytes. |
| `decodeIdent32` | `(bytes32) pure returns (string memory)` | bytes32 → string. Strips trailing zeros. |

`encodeIdent32` replaces the test-only `Lib.packName` helper with a production function. `decodeIdent32` is the inverse for off-chain readability (view functions, event indexing).

### Files

| File | Change |
|---|---|
| `src/Ident32.sol` | New — free functions: `validateIdent32`, `encodeIdent32`, `decodeIdent32`, bitmap constant, errors |
| `src/EntityHashing.sol` | Add `validateIdent32(attr.name)` call in `attributeHash` |
| `test/utils/Lib.sol` | Replace `packName` body with `encodeIdent32` delegation |
| `test/unit/Ident32.t.sol` | New — validation tests (charset, leading byte, empty, embedded nulls, boundary bytes, all uppercase rejected) |
| `test/unit/hashing/AttributeHash.t.sol` | Fuzz tests need `vm.assume` for valid charset; new tests for uppercase/invalid name rejection |

### Errors

```solidity
error Ident32Empty();
error Ident32TooLong(uint256 length);
error Ident32InvalidByte(uint256 position, bytes1 value);
```

### Comparison with OpenZeppelin ShortStrings

OpenZeppelin provides [`ShortStrings.sol`](https://github.com/OpenZeppelin/openzeppelin-contracts/blob/master/contracts/utils/ShortStrings.sol) — a `bytes32` string encoding used primarily for EIP-712 domain names and versions. It solves a different problem, but the comparison is instructive.

**How OZ ShortString works**: Packs a string of up to 31 bytes into a `bytes32` using `type ShortString is bytes32`. The string data occupies the high 31 bytes (left-aligned), and the lowest byte stores the length. Strings longer than 31 bytes fall back to a separate `string storage` slot, with a sentinel value (`0xFF` in the length byte) indicating the fallback.

| Aspect | OZ ShortString | Ident32 |
|---|---|---|
| **Max length** | 31 bytes (1 byte reserved for length) | 32 bytes (full word) |
| **Length tracking** | Stored in lowest byte of the word | Derived by scanning for trailing zeros |
| **Type safety** | `type ShortString is bytes32` (UDT) | Bare `bytes32` (no wrapper) |
| **Charset validation** | None — accepts any bytes | Bitmap-validated identifier charset (`a-z 0-9 . - _`) |
| **Leading char rule** | None | Must be `a-z` |
| **Fallback for long strings** | Writes to `string storage` + sentinel | Reverts — no fallback |
| **Primary use case** | Immutable config strings (EIP-712 name/version) | Validated identifiers in calldata (attribute names) |

**Why not use OZ ShortString:**

1. **Length byte costs a slot.** OZ reserves the lowest byte for length, capping content at 31 bytes. Attribute names are already left-aligned `bytes32` with trailing zeros throughout the codebase — the length is implicit. Switching to OZ encoding would waste a byte and require re-encoding every existing name, changing the EIP-712 `ATTRIBUTE_TYPEHASH`, and breaking hash compatibility.

2. **No charset validation.** OZ ShortString accepts any byte sequence. The entire point of our validation is rejecting uppercase, control chars, and non-identifier characters. We'd need to add validation on top of OZ anyway, gaining nothing from the dependency.

3. **Fallback mechanism is unnecessary.** Attribute names that don't fit in 32 bytes are invalid — they should revert, not silently spill to storage. The fallback pattern adds complexity for a code path we explicitly forbid.

4. **Type wrapper conflicts with existing layout.** The `Attribute` struct uses bare `bytes32 name`. Wrapping it in `type ShortString is bytes32` would change the struct's ABI encoding, the typehash, and every call site. The wrapper provides type safety but at a high migration cost for a field that is unambiguous in context.

**What we take from OZ:** The left-aligned, zero-padded encoding is the same — OZ just adds a length byte we don't need. The `encodeIdent32` / `decodeIdent32` API mirrors OZ's `toShortString` / `toString` naming convention.

### Interaction with existing sort validation

The sort check in `attributeHash` (`attr.name <= prevName`) operates on raw `bytes32` comparison. Since the identifier charset preserves byte ordering (lowercase `a` < `b` < `z`, digits sort before letters, separators sort between digits and letters), the existing lexicographic sort on `bytes32` produces the same ordering as ASCII string comparison. No change needed.

### Test plan

**Ident32.t.sol** (new):
- Encode/decode roundtrip for various lengths (1, 16, 31, 32 bytes)
- Encode revert on empty, >32 bytes
- Validate accepts lowercase alpha (`a-z`), digits (`0-9`), dot, hyphen, underscore
- Validate rejects leading digit (`0count`), leading dot (`.hidden`), leading hyphen (`-flag`), leading underscore (`_private`)
- Validate accepts leading lowercase letter
- Validate rejects each uppercase letter (A–Z) in any position
- Validate rejects space, control chars, DEL, high bytes
- Validate rejects all printable ASCII outside the identifier set (`!`, `@`, `#`, `/`, `:`, `;`, etc.)
- Validate rejects embedded null (e.g., `"ab\0cd"`)
- Validate returns correct length
- Bitmap spot checks: every valid char set, every adjacent invalid char unset

**AttributeHash.t.sol** (updated):
- Existing fuzz tests add `vm.assume` to constrain names to valid charset
- New test: uppercase attribute name reverts with `Ident32InvalidByte`
- New test: control char in name reverts
- New test: valid lowercase name passes through to hash

## Open questions

None currently outstanding.
