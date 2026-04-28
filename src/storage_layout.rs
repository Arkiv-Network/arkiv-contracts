//! Storage layout constants and key-packing helpers for `EntityRegistry`.
//!
//! These let off-chain consumers (notably the `arkiv-op-reth` ExEx) read
//! `EntityRegistry`'s slots directly at historical block state — without
//! spinning up an EVM — to recompute the rolling changeset hash.
//!
//! The constants below mirror the contract layout. Drift is caught by
//! [`tests::storage_layout_matches_artifact`], which re-parses the Foundry
//! artifact's `storageLayout.storage` section and asserts an exact match.
//!
//! Slots `0` and `1` are owned by OpenZeppelin's `EIP712` base
//! (`_nameFallback`, `_versionFallback`); `EntityRegistry`'s own state
//! starts at slot `2`.

use alloy_primitives::{Address, B256, U256, keccak256};

use crate::{BlockNode, Commitment};

// -----------------------------------------------------------------------------
// Slot indices
// -----------------------------------------------------------------------------

/// `mapping(address owner => uint32) _nonces`.
pub const NONCES_SLOT: u64 = 2;

/// `mapping(bytes32 entityKey => Entity.Commitment) _commitments`.
pub const COMMITMENTS_SLOT: u64 = 3;

/// `mapping(OperationKey operationKey => bytes32 changeSetHash) _hashAt`.
pub const HASH_AT_SLOT: u64 = 4;

/// `mapping(TransactionKey transactionKey => uint32 opCount) _txOpCount`.
pub const TX_OP_COUNT_SLOT: u64 = 5;

/// `mapping(BlockNumber blockNumber => Entity.BlockNode node) _blocks`.
pub const BLOCKS_SLOT: u64 = 6;

/// `BlockNumber _headBlock` — single-value slot (uint32 in the low 4 bytes).
pub const HEAD_BLOCK_SLOT: u64 = 7;

// -----------------------------------------------------------------------------
// Key packing — must match Entity.sol exactly
// -----------------------------------------------------------------------------

/// Pack `(block, tx)` matching `Entity.sol::transactionKey()`.
///
/// Layout: `block` in bits `[32..63]`, `tx` in bits `[0..31]`.
pub fn transaction_key(block: u32, tx: u32) -> U256 {
    U256::from((u64::from(block) << 32) | u64::from(tx))
}

/// Pack `(block, tx, op)` matching `Entity.sol::operationKey()`.
///
/// Layout: `block` in bits `[64..95]`, `tx` in bits `[32..63]`, `op` in bits
/// `[0..31]`.
pub fn operation_key(block: u32, tx: u32, op: u32) -> U256 {
    let lo = (u64::from(tx) << 32) | u64::from(op);
    (U256::from(block) << 64) | U256::from(lo)
}

/// Compute the storage slot of `mapping[key]` at the given mapping base slot:
/// `keccak256(abi.encode(key, slot))`.
///
/// `key` is the 32-byte ABI-encoded mapping key. For value types narrower than
/// 32 bytes (e.g. `address`, `uint32`, `BlockNumber`, `OperationKey`), the
/// caller must left-pad to 32 bytes per Solidity ABI rules.
pub fn mapping_slot(slot: u64, key: B256) -> B256 {
    let mut buf = [0u8; 64];
    buf[0..32].copy_from_slice(key.as_slice());
    buf[32..64].copy_from_slice(&U256::from(slot).to_be_bytes::<32>());
    keccak256(buf)
}

// -----------------------------------------------------------------------------
// Slot calculators (per accessor)
// -----------------------------------------------------------------------------

/// Storage slot of `_nonces[owner]`.
pub fn nonces_slot(owner: Address) -> B256 {
    mapping_slot(NONCES_SLOT, pad_address(owner))
}

/// Storage slots of `_commitments[entityKey]`. The struct spans three
/// consecutive slots (see [`decode_commitment`]).
pub fn commitment_slots(entity_key: B256) -> [B256; 3] {
    let base = mapping_slot(COMMITMENTS_SLOT, entity_key);
    [base, slot_add(base, 1), slot_add(base, 2)]
}

/// Storage slot of `_hashAt[operationKey(block, tx, op)]`.
pub fn hash_at_slot(block: u32, tx: u32, op: u32) -> B256 {
    mapping_slot(HASH_AT_SLOT, B256::from(operation_key(block, tx, op)))
}

/// Storage slot of `_txOpCount[transactionKey(block, tx)]`.
pub fn tx_op_count_slot(block: u32, tx: u32) -> B256 {
    mapping_slot(TX_OP_COUNT_SLOT, B256::from(transaction_key(block, tx)))
}

/// Storage slot of `_blocks[block]`. The struct fits in a single slot
/// (see [`decode_block_node`]).
pub fn block_node_slot(block: u32) -> B256 {
    mapping_slot(BLOCKS_SLOT, pad_u32(block))
}

/// Storage slot of `_headBlock`.
pub fn head_block_slot() -> B256 {
    B256::from(U256::from(HEAD_BLOCK_SLOT))
}

// -----------------------------------------------------------------------------
// Decoders (raw storage word → typed value)
// -----------------------------------------------------------------------------
//
// Solidity packs the first declared field at the *low-order* end of a slot.
// When a slot is read as a 32-byte big-endian word, a member at byte `offset`
// (from the LSB) of width `w` lives at indices `[32-offset-w .. 32-offset]`
// of the word.

/// Decode `_headBlock` from its slot word.
pub fn decode_head_block(word: B256) -> u32 {
    read_u32(word, 0)
}

/// Decode a `_nonces[owner]` slot word.
pub fn decode_nonce(word: B256) -> u32 {
    read_u32(word, 0)
}

/// Decode a `_txOpCount[k]` slot word.
pub fn decode_tx_op_count(word: B256) -> u32 {
    read_u32(word, 0)
}

/// Decode a `_hashAt[k]` slot word. Identity — provided for symmetry so all
/// access paths are `(slot_fn, decode_fn)` pairs.
pub fn decode_hash_at(word: B256) -> B256 {
    word
}

/// Decode a `_blocks[block]` slot word.
pub fn decode_block_node(word: B256) -> BlockNode {
    BlockNode {
        prevBlock: read_u32(word, 0),
        nextBlock: read_u32(word, 4),
        txCount: read_u32(word, 8),
    }
}

/// Decode `_commitments[entityKey]` from its three consecutive slot words.
///
/// Word order must match [`commitment_slots`]: `[base, base+1, base+2]`.
pub fn decode_commitment(words: [B256; 3]) -> Commitment {
    Commitment {
        creator: read_address(words[0], 0),
        createdAt: read_u32(words[0], 20),
        updatedAt: read_u32(words[0], 24),
        expiresAt: read_u32(words[0], 28),
        owner: read_address(words[1], 0),
        coreHash: words[2],
    }
}

// -----------------------------------------------------------------------------
// Internal packing helpers
// -----------------------------------------------------------------------------

fn pad_address(a: Address) -> B256 {
    let mut buf = [0u8; 32];
    buf[12..32].copy_from_slice(a.as_slice());
    B256::from(buf)
}

fn pad_u32(n: u32) -> B256 {
    let mut buf = [0u8; 32];
    buf[28..32].copy_from_slice(&n.to_be_bytes());
    B256::from(buf)
}

fn slot_add(base: B256, n: u64) -> B256 {
    let v = U256::from_be_bytes(base.0).wrapping_add(U256::from(n));
    B256::from(v.to_be_bytes::<32>())
}

/// Read a `uint32` from byte offset `offset` (measured from the LSB end of
/// the slot) within `word`.
fn read_u32(word: B256, offset: usize) -> u32 {
    let start = 32 - offset - 4;
    u32::from_be_bytes(word.0[start..start + 4].try_into().unwrap())
}

/// Read an `address` (20 bytes) from byte offset `offset` (measured from the
/// LSB end of the slot) within `word`.
fn read_address(word: B256, offset: usize) -> Address {
    let start = 32 - offset - 20;
    Address::from_slice(&word.0[start..start + 20])
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Expected `(label, slot)` sequence for `EntityRegistry`. Any rename,
    /// reorder, insertion, or removal in the contract makes this fail.
    /// Slots 0 and 1 belong to the inherited `EIP712` base.
    const EXPECTED_LAYOUT: &[(&str, u64)] = &[
        ("_nameFallback", 0),
        ("_versionFallback", 1),
        ("_nonces", NONCES_SLOT),
        ("_commitments", COMMITMENTS_SLOT),
        ("_hashAt", HASH_AT_SLOT),
        ("_txOpCount", TX_OP_COUNT_SLOT),
        ("_blocks", BLOCKS_SLOT),
        ("_headBlock", HEAD_BLOCK_SLOT),
    ];

    /// Expected `(label, slot, offset)` packing for `Entity.BlockNode`.
    /// All three fields share slot 0 (12 bytes total).
    const EXPECTED_BLOCK_NODE: &[(&str, u64, u64)] =
        &[("prevBlock", 0, 0), ("nextBlock", 0, 4), ("txCount", 0, 8)];

    /// Expected `(label, slot, offset)` packing for `Entity.Commitment`.
    /// Slot 0: creator+createdAt+updatedAt+expiresAt; slot 1: owner; slot 2: coreHash.
    const EXPECTED_COMMITMENT: &[(&str, u64, u64)] = &[
        ("creator", 0, 0),
        ("createdAt", 0, 20),
        ("updatedAt", 0, 24),
        ("expiresAt", 0, 28),
        ("owner", 1, 0),
        ("coreHash", 2, 0),
    ];

    fn artifact_json() -> serde_json::Value {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/out/EntityRegistry.sol/EntityRegistry.json"
        );
        let raw = std::fs::read_to_string(path).expect("artifact missing — run `forge build`");
        serde_json::from_str(&raw).expect("artifact is not valid JSON")
    }

    /// Locate a struct entry in `storageLayout.types` by label suffix
    /// (e.g. `"struct Entity.BlockNode"`).
    fn find_struct_members<'a>(
        json: &'a serde_json::Value,
        struct_label: &str,
    ) -> &'a Vec<serde_json::Value> {
        let types = json["storageLayout"]["types"]
            .as_object()
            .expect("storageLayout.types missing");
        for (_id, ty) in types {
            if ty["label"].as_str() == Some(struct_label) {
                return ty["members"].as_array().expect("members");
            }
        }
        panic!("struct {} not found in storageLayout.types", struct_label);
    }

    fn members_to_tuples(members: &[serde_json::Value]) -> Vec<(String, u64, u64)> {
        members
            .iter()
            .map(|m| {
                let label = m["label"].as_str().expect("label").to_string();
                let slot: u64 = m["slot"]
                    .as_str()
                    .expect("slot")
                    .parse()
                    .expect("slot parse");
                let offset: u64 = m["offset"].as_u64().expect("offset");
                (label, slot, offset)
            })
            .collect()
    }

    fn expected_to_tuples(expected: &[(&str, u64, u64)]) -> Vec<(String, u64, u64)> {
        expected
            .iter()
            .map(|(l, s, o)| ((*l).to_string(), *s, *o))
            .collect()
    }

    /// Re-parse the Foundry artifact and assert that the on-disk storage
    /// layout matches [`EXPECTED_LAYOUT`] exactly. This is the drift guard:
    /// any change to `EntityRegistry`'s state variables that isn't reflected
    /// in this module fails the suite.
    #[test]
    fn storage_layout_matches_artifact() {
        let json = artifact_json();

        let storage = json["storageLayout"]["storage"]
            .as_array()
            .expect("storageLayout.storage missing from artifact");

        let actual: Vec<(String, u64)> = storage
            .iter()
            .map(|entry| {
                let label = entry["label"].as_str().expect("label").to_string();
                let slot: u64 = entry["slot"]
                    .as_str()
                    .expect("slot")
                    .parse()
                    .expect("slot parse");
                (label, slot)
            })
            .collect();

        let expected: Vec<(String, u64)> = EXPECTED_LAYOUT
            .iter()
            .map(|(l, s)| ((*l).to_string(), *s))
            .collect();

        assert_eq!(
            actual, expected,
            "EntityRegistry storage layout drifted. Update `storage_layout.rs` \
             constants and EXPECTED_LAYOUT to match `forge inspect EntityRegistry storageLayout`."
        );
    }

    /// Drift guard for `BlockNode` field packing. Re-decoders silently
    /// produce wrong values if the contract repacks the struct, so the
    /// expected `(slot, offset)` for each member is asserted against the
    /// artifact.
    #[test]
    fn block_node_packing_matches_artifact() {
        let json = artifact_json();
        let members = find_struct_members(&json, "struct Entity.BlockNode");
        assert_eq!(
            members_to_tuples(members),
            expected_to_tuples(EXPECTED_BLOCK_NODE),
            "Entity.BlockNode packing drifted — update decode_block_node."
        );
    }

    /// Drift guard for `Commitment` field packing across its three slots.
    #[test]
    fn commitment_packing_matches_artifact() {
        let json = artifact_json();
        let members = find_struct_members(&json, "struct Entity.Commitment");
        assert_eq!(
            members_to_tuples(members),
            expected_to_tuples(EXPECTED_COMMITMENT),
            "Entity.Commitment packing drifted — update decode_commitment."
        );
    }

    #[test]
    fn transaction_key_packs_block_and_tx() {
        // block in [32..63], tx in [0..31]
        assert_eq!(transaction_key(0, 0), U256::ZERO);
        assert_eq!(transaction_key(0, 1), U256::from(1u64));
        assert_eq!(transaction_key(1, 0), U256::from(1u64 << 32));
        assert_eq!(
            transaction_key(0x0a0b0c0d, 0x01020304),
            U256::from(0x0a0b_0c0d_0102_0304u64)
        );
        assert_eq!(transaction_key(u32::MAX, u32::MAX), U256::from(u64::MAX));
    }

    #[test]
    fn operation_key_packs_block_tx_op() {
        assert_eq!(operation_key(0, 0, 0), U256::ZERO);
        assert_eq!(operation_key(0, 0, 7), U256::from(7u64));
        assert_eq!(operation_key(0, 5, 0), U256::from(5u64 << 32));
        assert_eq!(operation_key(9, 0, 0), U256::from(9u64) << 64);

        // Composite: block=0xAA, tx=0xBB, op=0xCC
        let expected =
            (U256::from(0xAAu64) << 64) | (U256::from(0xBBu64) << 32) | U256::from(0xCCu64);
        assert_eq!(operation_key(0xAA, 0xBB, 0xCC), expected);
    }

    #[test]
    fn operation_key_extends_transaction_key() {
        // Per Entity.sol: operationKey(b, t, o) == (transactionKey(b, t) << 32) | o
        let b = 0x1234_5678u32;
        let t = 0x9abc_def0u32;
        let o = 0x0fed_cba9u32;
        let expected = (transaction_key(b, t) << 32) | U256::from(o);
        assert_eq!(operation_key(b, t, o), expected);
    }

    #[test]
    fn mapping_slot_known_vector() {
        // keccak256(abi.encode(bytes32(0), uint256(0))) — keccak of 64 zero
        // bytes. Verified independently with `cast keccak`:
        //   0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5
        let got = mapping_slot(0, B256::ZERO);
        let expected: B256 = "0xad3228b676f7d3cd4284a5443f17f1962b36e491b30a40b2405849e597ba5fb5"
            .parse()
            .unwrap();
        assert_eq!(got, expected);
    }

    // -------------------------------------------------------------------------
    // Slot calculators
    // -------------------------------------------------------------------------

    #[test]
    fn nonces_slot_matches_manual() {
        let owner = Address::repeat_byte(0xAB);
        let mut key = [0u8; 32];
        key[12..32].copy_from_slice(owner.as_slice());
        let expected = mapping_slot(NONCES_SLOT, B256::from(key));
        assert_eq!(nonces_slot(owner), expected);
    }

    #[test]
    fn commitment_slots_are_consecutive() {
        let key = B256::repeat_byte(0x77);
        let base = mapping_slot(COMMITMENTS_SLOT, key);
        let slots = commitment_slots(key);
        assert_eq!(slots[0], base);
        assert_eq!(slots[1], slot_add(base, 1));
        assert_eq!(slots[2], slot_add(base, 2));
    }

    #[test]
    fn hash_at_slot_matches_manual() {
        let (b, t, o) = (12u32, 3u32, 5u32);
        let key = B256::from(operation_key(b, t, o));
        assert_eq!(hash_at_slot(b, t, o), mapping_slot(HASH_AT_SLOT, key));
    }

    #[test]
    fn tx_op_count_slot_matches_manual() {
        let (b, t) = (42u32, 7u32);
        let key = B256::from(transaction_key(b, t));
        assert_eq!(tx_op_count_slot(b, t), mapping_slot(TX_OP_COUNT_SLOT, key));
    }

    #[test]
    fn block_node_slot_matches_manual() {
        let b = 0xdead_beefu32;
        let mut key = [0u8; 32];
        key[28..32].copy_from_slice(&b.to_be_bytes());
        assert_eq!(
            block_node_slot(b),
            mapping_slot(BLOCKS_SLOT, B256::from(key))
        );
    }

    #[test]
    fn head_block_slot_is_constant() {
        assert_eq!(head_block_slot(), B256::from(U256::from(HEAD_BLOCK_SLOT)));
    }

    // -------------------------------------------------------------------------
    // Decoders
    // -------------------------------------------------------------------------

    /// Build a 32-byte slot word with the rightmost (low-order) bytes set
    /// from `low_bytes_be`. Mirrors how Solidity packs values into a slot.
    fn slot_word(low_bytes_be: &[u8]) -> B256 {
        assert!(low_bytes_be.len() <= 32);
        let mut buf = [0u8; 32];
        buf[32 - low_bytes_be.len()..].copy_from_slice(low_bytes_be);
        B256::from(buf)
    }

    #[test]
    fn decode_head_block_reads_low_u32() {
        let word = slot_word(&0x1234_5678u32.to_be_bytes());
        assert_eq!(decode_head_block(word), 0x1234_5678);
    }

    #[test]
    fn decode_block_node_unpacks_three_u32s() {
        // Slot layout (LSB → MSB): prev (4) | next (4) | txCount (4) | zero (20)
        // As a big-endian word: [zero..][txCount][next][prev]
        let mut bytes = [0u8; 32];
        bytes[20..24].copy_from_slice(&0xCAFEu32.to_be_bytes()); // txCount @ offset 8
        bytes[24..28].copy_from_slice(&0xBEEFu32.to_be_bytes()); // nextBlock @ offset 4
        bytes[28..32].copy_from_slice(&0xDEADu32.to_be_bytes()); // prevBlock @ offset 0
        let node = decode_block_node(B256::from(bytes));
        assert_eq!(node.prevBlock, 0xDEAD);
        assert_eq!(node.nextBlock, 0xBEEF);
        assert_eq!(node.txCount, 0xCAFE);
    }

    #[test]
    fn decode_commitment_unpacks_three_slots() {
        let creator = Address::repeat_byte(0x11);
        let owner = Address::repeat_byte(0x22);
        let core = B256::repeat_byte(0x33);
        let (created, updated, expires) = (100u32, 200u32, 300u32);

        // Slot 0: [zero(20)][expiresAt(4)][updatedAt(4)][createdAt(4)][creator(20)]
        // Wait — creator is 20 bytes at offset 0, then BlockNumbers at 20/24/28.
        // BE word: [expiresAt][updatedAt][createdAt][creator]
        let mut s0 = [0u8; 32];
        s0[0..4].copy_from_slice(&expires.to_be_bytes()); // offset 28
        s0[4..8].copy_from_slice(&updated.to_be_bytes()); // offset 24
        s0[8..12].copy_from_slice(&created.to_be_bytes()); // offset 20
        s0[12..32].copy_from_slice(creator.as_slice()); // offset 0

        // Slot 1: owner left-padded.
        let mut s1 = [0u8; 32];
        s1[12..32].copy_from_slice(owner.as_slice());

        let c = decode_commitment([B256::from(s0), B256::from(s1), core]);
        assert_eq!(c.creator, creator);
        assert_eq!(c.createdAt, created);
        assert_eq!(c.updatedAt, updated);
        assert_eq!(c.expiresAt, expires);
        assert_eq!(c.owner, owner);
        assert_eq!(c.coreHash, core);
    }

    #[test]
    fn decode_hash_at_is_identity() {
        let w = B256::repeat_byte(0xAB);
        assert_eq!(decode_hash_at(w), w);
    }

    #[test]
    fn mapping_slot_matches_keccak_of_concat() {
        // Sanity: mapping_slot is keccak256(key || slot_be32).
        let key = B256::repeat_byte(0xab);
        let slot: u64 = HASH_AT_SLOT;
        let mut buf = [0u8; 64];
        buf[0..32].copy_from_slice(key.as_slice());
        buf[32..64].copy_from_slice(&U256::from(slot).to_be_bytes::<32>());
        assert_eq!(mapping_slot(slot, key), keccak256(buf));
    }
}
