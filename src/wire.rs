//! Wire-format types matching the v2 ExEx → EntityDB JSON-RPC interface
//! (`arkiv-op-reth/docs/exex-jsonrpc-interface-v2.md`).
//!
//! These are the **typed data target** for decoded EntityRegistry
//! operations: a tagged enum per operation type plus a typed attribute
//! enum, both serializing to the JSON shape the EntityDB consumes.
//!
//! Scope is intentionally narrow: just operations and attributes. Block,
//! transaction, and block-ref envelopes live in the consumer (op-reth)
//! because they're built from reth-specific inputs (`RecoveredBlock`,
//! signature recovery, etc.).
//!
//! Decoding is byte-exact and non-lossy. ATTR_STRING is exposed as
//! `FixedBytes<128>` — the protocol treats those 128 bytes as opaque,
//! so the bindings preserve them verbatim. UTF-8 (or any other charset)
//! interpretation is the consumer's choice.
//!
//! Serde annotations are gated behind the `serde-wire` feature (default on).

use alloy_primitives::{Address, B256, Bytes, FixedBytes, U256};
use eyre::{Result, bail};

#[cfg(feature = "serde-wire")]
use serde::Serialize;

use crate::IEntityRegistry::{ChangeSetHashUpdate, EntityOperation};
use crate::types::{Ident32, Mime128Str};
use crate::{
    ATTR_ENTITY_KEY, ATTR_STRING, ATTR_UINT, Attribute as CalldataAttribute, OP_CREATE, OP_DELETE,
    OP_EXPIRE, OP_EXTEND, OP_TRANSFER, OP_UPDATE, Operation as CalldataOp,
};

// -----------------------------------------------------------------------------
// Operation enum + per-op structs
// -----------------------------------------------------------------------------

/// A decoded EntityRegistry operation, tagged by type.
///
/// JSON shape per v2 wire spec: `{"type": "create" | "update" | …, …fields}`.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(tag = "type", rename_all = "camelCase"))]
pub enum Operation {
    Create(CreateOp),
    Update(UpdateOp),
    Extend(ExtendOp),
    Transfer(TransferOp),
    Delete(DeleteOp),
    Expire(ExpireOp),
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(rename_all = "camelCase"))]
pub struct CreateOp {
    pub op_index: u32,
    pub entity_key: B256,
    pub owner: Address,
    #[cfg_attr(feature = "serde-wire", serde(with = "hex_u64"))]
    pub expires_at: u64,
    pub entity_hash: B256,
    pub changeset_hash: B256,
    pub payload: Bytes,
    pub content_type: Mime128Str,
    pub attributes: Vec<Attribute>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(rename_all = "camelCase"))]
pub struct UpdateOp {
    pub op_index: u32,
    pub entity_key: B256,
    pub owner: Address,
    pub entity_hash: B256,
    pub changeset_hash: B256,
    pub payload: Bytes,
    pub content_type: Mime128Str,
    pub attributes: Vec<Attribute>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(rename_all = "camelCase"))]
pub struct ExtendOp {
    pub op_index: u32,
    pub entity_key: B256,
    pub owner: Address,
    #[cfg_attr(feature = "serde-wire", serde(with = "hex_u64"))]
    pub expires_at: u64,
    pub entity_hash: B256,
    pub changeset_hash: B256,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(rename_all = "camelCase"))]
pub struct TransferOp {
    pub op_index: u32,
    pub entity_key: B256,
    pub owner: Address,
    pub entity_hash: B256,
    pub changeset_hash: B256,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(rename_all = "camelCase"))]
pub struct DeleteOp {
    pub op_index: u32,
    pub entity_key: B256,
    pub owner: Address,
    pub entity_hash: B256,
    pub changeset_hash: B256,
}

#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(rename_all = "camelCase"))]
pub struct ExpireOp {
    pub op_index: u32,
    pub entity_key: B256,
    pub owner: Address,
    pub entity_hash: B256,
    pub changeset_hash: B256,
}

// -----------------------------------------------------------------------------
// Attribute enum
// -----------------------------------------------------------------------------

/// A typed attribute, mirroring the on-chain `Attribute { name, valueType,
/// value }` shape. The variant carries the value's natural Rust type at
/// the natural size for that `valueType`:
///
/// - `Uint`      — `U256` (right-aligned in `data[0]` on-chain)
/// - `String`    — `FixedBytes<128>` (the full `bytes32[4]` container,
///   byte-exact). The protocol treats ATTR_STRING as opaque bytes; UTF-8
///   is convention only and is the consumer's call to interpret.
/// - `EntityKey` — `B256` (== `FixedBytes<32>`, in `data[0]` on-chain)
///
/// `valueType` is reified on the wire as the serde tag so JSON consumers
/// see exactly the same three fields the contract defines.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(
    feature = "serde-wire",
    serde(tag = "valueType", rename_all = "camelCase")
)]
pub enum Attribute {
    Uint {
        name: Ident32,
        value: U256,
    },
    String {
        name: Ident32,
        value: FixedBytes<128>,
    },
    EntityKey {
        name: Ident32,
        value: B256,
    },
}

// -----------------------------------------------------------------------------
// Decoder
// -----------------------------------------------------------------------------

/// Build a typed [`Operation`] from a single decoded calldata op plus the
/// two paired event records (`EntityOperation` and `ChangeSetHashUpdate`).
///
/// Inputs:
/// - `op_index`: the operation's position within its transaction's `ops[]`
/// - `calldata`: the `Operation` struct from `executeCall::abi_decode`
/// - `entity_event`: the `EntityOperation` event emitted for this op
/// - `hash_event`: the `ChangeSetHashUpdate` event emitted for this op
///
/// Errors:
/// - `entity_event.operationType` doesn't match `calldata.operationType`
/// - Unknown operation type
/// - Attribute name fails Ident32 decode
/// - Attribute value_type is unknown or violates natural-size invariants
pub fn decode_operation(
    op_index: u32,
    calldata: &CalldataOp,
    entity_event: &EntityOperation,
    hash_event: &ChangeSetHashUpdate,
) -> Result<Operation> {
    if entity_event.operationType != calldata.operationType {
        bail!(
            "event/calldata operationType mismatch: event={}, calldata={}",
            entity_event.operationType,
            calldata.operationType,
        );
    }

    let entity_key = entity_event.entityKey;
    let owner = entity_event.owner;
    let entity_hash = entity_event.entityHash;
    let changeset_hash = hash_event.changeSetHash;
    let expires_at = u64::from(calldata.expiresAt);

    Ok(match calldata.operationType {
        OP_CREATE => Operation::Create(CreateOp {
            op_index,
            entity_key,
            owner,
            expires_at,
            entity_hash,
            changeset_hash,
            payload: calldata.payload.clone(),
            content_type: Mime128Str::try_from(&calldata.contentType)?,
            attributes: decode_attributes(&calldata.attributes)?,
        }),
        OP_UPDATE => Operation::Update(UpdateOp {
            op_index,
            entity_key,
            owner,
            entity_hash,
            changeset_hash,
            payload: calldata.payload.clone(),
            content_type: Mime128Str::try_from(&calldata.contentType)?,
            attributes: decode_attributes(&calldata.attributes)?,
        }),
        OP_EXTEND => Operation::Extend(ExtendOp {
            op_index,
            entity_key,
            owner,
            expires_at,
            entity_hash,
            changeset_hash,
        }),
        OP_TRANSFER => Operation::Transfer(TransferOp {
            op_index,
            entity_key,
            owner,
            entity_hash,
            changeset_hash,
        }),
        OP_DELETE => Operation::Delete(DeleteOp {
            op_index,
            entity_key,
            owner,
            entity_hash,
            changeset_hash,
        }),
        OP_EXPIRE => Operation::Expire(ExpireOp {
            op_index,
            entity_key,
            owner,
            entity_hash,
            changeset_hash,
        }),
        other => bail!("unknown operation type: {}", other),
    })
}

fn decode_attributes(attrs: &[CalldataAttribute]) -> Result<Vec<Attribute>> {
    attrs.iter().map(decode_attribute).collect()
}

fn decode_attribute(attr: &CalldataAttribute) -> Result<Attribute> {
    let name = Ident32::try_from(attr.name)?;

    match attr.valueType {
        ATTR_UINT => {
            require_single_word(&attr.value, attr.valueType)?;
            Ok(Attribute::Uint {
                name,
                value: U256::from_be_bytes(attr.value[0].0),
            })
        }
        ATTR_STRING => {
            // Concat 4 words into a single 128-byte buffer, byte-exact.
            // No NUL-truncation, no UTF-8 — the protocol is opaque on the
            // contents of this field.
            let mut buf = [0u8; 128];
            for (i, w) in attr.value.iter().enumerate() {
                buf[i * 32..(i + 1) * 32].copy_from_slice(w.as_slice());
            }
            Ok(Attribute::String {
                name,
                value: FixedBytes::from(buf),
            })
        }
        ATTR_ENTITY_KEY => {
            require_single_word(&attr.value, attr.valueType)?;
            Ok(Attribute::EntityKey {
                name,
                value: attr.value[0],
            })
        }
        other => bail!("unknown attribute value_type: {}", other),
    }
}

/// Enforce the bytes32-sized invariant (natural size of UINT and ENTITY_KEY):
/// `value[1..=3]` must be zero.
fn require_single_word(value: &[FixedBytes<32>; 4], value_type: u8) -> Result<()> {
    for (i, w) in value.iter().enumerate().skip(1) {
        if w.0 != [0u8; 32] {
            bail!(
                "value_type {} expects bytes32 (data[1..=3] zero), but data[{}] is non-zero",
                value_type,
                i,
            );
        }
    }
    Ok(())
}

// -----------------------------------------------------------------------------
// Hex u64 serializer — block numbers, expiry are JSON hex strings ("0x…").
// -----------------------------------------------------------------------------

#[cfg(feature = "serde-wire")]
pub mod hex_u64 {
    use serde::Serializer;

    pub fn serialize<S: Serializer>(val: &u64, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&format!("0x{:x}", val))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::Mime128;
    use alloy_primitives::FixedBytes;

    fn ident32(name: &str) -> B256 {
        let mut bytes = [0u8; 32];
        bytes[..name.len()].copy_from_slice(name.as_bytes());
        B256::from(bytes)
    }

    fn mime128(s: &str) -> Mime128 {
        let bytes = s.as_bytes();
        let mut buf = [0u8; 128];
        buf[..bytes.len()].copy_from_slice(bytes);
        let mut data = [FixedBytes::ZERO; 4];
        for (i, w) in data.iter_mut().enumerate() {
            *w = FixedBytes::from_slice(&buf[i * 32..(i + 1) * 32]);
        }
        Mime128 { data }
    }

    fn u256_word(v: u64) -> [FixedBytes<32>; 4] {
        let mut data = [FixedBytes::ZERO; 4];
        data[0] = FixedBytes::from(U256::from(v).to_be_bytes::<32>());
        data
    }

    /// Build a `bytes32[4]` calldata value from a 128-byte buffer.
    fn calldata_value(buf: [u8; 128]) -> [FixedBytes<32>; 4] {
        let mut data = [FixedBytes::ZERO; 4];
        for (i, w) in data.iter_mut().enumerate() {
            *w = FixedBytes::from_slice(&buf[i * 32..(i + 1) * 32]);
        }
        data
    }

    /// Pack a string into the on-chain ATTR_STRING wire shape (left-aligned,
    /// zero-padded). The wire decoder preserves the full 128 bytes; tests
    /// likewise compare the full 128-byte buffer.
    fn string_buf(s: &str) -> [u8; 128] {
        let mut buf = [0u8; 128];
        buf[..s.len()].copy_from_slice(s.as_bytes());
        buf
    }

    fn entity_event(op_type: u8) -> EntityOperation {
        EntityOperation {
            entityKey: B256::repeat_byte(0xE1),
            operationType: op_type,
            owner: Address::repeat_byte(0xAA),
            expiresAt: 1234,
            entityHash: B256::repeat_byte(0xE2),
        }
    }

    fn hash_event() -> ChangeSetHashUpdate {
        ChangeSetHashUpdate {
            entityKey: B256::repeat_byte(0xE1),
            operationKey: U256::from(0xAABBCC_u64),
            changeSetHash: B256::repeat_byte(0xC1),
        }
    }

    fn calldata_op(op_type: u8) -> CalldataOp {
        CalldataOp {
            operationType: op_type,
            entityKey: B256::ZERO,
            payload: Bytes::from_static(b"hello"),
            contentType: mime128("text/plain"),
            attributes: vec![],
            expiresAt: 1234,
            newOwner: Address::ZERO,
        }
    }

    #[test]
    fn decode_create_populates_body_fields() {
        let op = calldata_op(OP_CREATE);
        let decoded = decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap();
        let Operation::Create(c) = decoded else {
            panic!("expected Create variant");
        };
        assert_eq!(c.op_index, 0);
        assert_eq!(c.entity_key, B256::repeat_byte(0xE1));
        assert_eq!(c.owner, Address::repeat_byte(0xAA));
        assert_eq!(c.expires_at, 1234);
        assert_eq!(c.entity_hash, B256::repeat_byte(0xE2));
        assert_eq!(c.changeset_hash, B256::repeat_byte(0xC1));
        assert_eq!(c.payload, Bytes::from_static(b"hello"));
        assert_eq!(c.content_type.as_str(), "text/plain");
        assert!(c.attributes.is_empty());
    }

    #[test]
    fn decode_update_omits_expires_at() {
        let op = calldata_op(OP_UPDATE);
        let decoded = decode_operation(3, &op, &entity_event(OP_UPDATE), &hash_event()).unwrap();
        let Operation::Update(u) = decoded else {
            panic!("expected Update");
        };
        assert_eq!(u.op_index, 3);
        assert_eq!(u.payload, Bytes::from_static(b"hello"));
        // No expires_at on UpdateOp by design.
    }

    #[test]
    fn decode_extend_carries_expires_at_no_body() {
        let op = calldata_op(OP_EXTEND);
        let decoded = decode_operation(1, &op, &entity_event(OP_EXTEND), &hash_event()).unwrap();
        let Operation::Extend(e) = decoded else {
            panic!("expected Extend");
        };
        assert_eq!(e.expires_at, 1234);
    }

    #[test]
    fn decode_transfer_delete_expire_have_no_body() {
        for ty in [OP_TRANSFER, OP_DELETE, OP_EXPIRE] {
            let op = calldata_op(ty);
            let decoded = decode_operation(0, &op, &entity_event(ty), &hash_event()).unwrap();
            match (ty, &decoded) {
                (OP_TRANSFER, Operation::Transfer(_)) => {}
                (OP_DELETE, Operation::Delete(_)) => {}
                (OP_EXPIRE, Operation::Expire(_)) => {}
                _ => panic!("variant mismatch for op_type {}: {:?}", ty, decoded),
            }
        }
    }

    #[test]
    fn decode_rejects_event_calldata_mismatch() {
        let op = calldata_op(OP_CREATE);
        let err = decode_operation(0, &op, &entity_event(OP_DELETE), &hash_event())
            .unwrap_err()
            .to_string();
        assert!(err.contains("operationType mismatch"), "{}", err);
    }

    #[test]
    fn decode_rejects_unknown_op_type() {
        let mut op = calldata_op(OP_CREATE);
        op.operationType = 99;
        let mut ev = entity_event(OP_CREATE);
        ev.operationType = 99;
        let err = decode_operation(0, &op, &ev, &hash_event())
            .unwrap_err()
            .to_string();
        assert!(err.contains("99"), "{}", err);
    }

    #[test]
    fn decode_uint_attribute() {
        let mut op = calldata_op(OP_CREATE);
        op.attributes.push(CalldataAttribute {
            name: ident32("count"),
            valueType: ATTR_UINT,
            value: u256_word(42),
        });
        let Operation::Create(c) =
            decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap()
        else {
            unreachable!();
        };
        assert_eq!(c.attributes.len(), 1);
        assert_eq!(
            c.attributes[0],
            Attribute::Uint {
                name: Ident32::encode("count").unwrap(),
                value: U256::from(42u64),
            },
        );
    }

    #[test]
    fn decode_string_attribute_byte_exact() {
        let buf = string_buf("hello");
        let mut op = calldata_op(OP_CREATE);
        op.attributes.push(CalldataAttribute {
            name: ident32("title"),
            valueType: ATTR_STRING,
            value: calldata_value(buf),
        });
        let Operation::Create(c) =
            decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap()
        else {
            unreachable!();
        };
        assert_eq!(
            c.attributes[0],
            Attribute::String {
                name: Ident32::encode("title").unwrap(),
                value: FixedBytes::from(buf),
            },
        );
    }

    #[test]
    fn decode_string_attribute_preserves_arbitrary_bytes() {
        // Non-UTF-8 bytes pass through verbatim — no UTF-8 attempted, no
        // NUL-truncation. The full 128 bytes are preserved.
        let mut buf = [0u8; 128];
        buf[0] = 0xFF;
        buf[1] = 0xFE;
        buf[10] = 0x00; // NUL in the middle
        buf[20] = b'x'; // bytes after the NUL must survive
        buf[127] = 0xAA;
        let mut op = calldata_op(OP_CREATE);
        op.attributes.push(CalldataAttribute {
            name: ident32("garbage"),
            valueType: ATTR_STRING,
            value: calldata_value(buf),
        });
        let Operation::Create(c) =
            decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap()
        else {
            unreachable!();
        };
        let Attribute::String { value, .. } = &c.attributes[0] else {
            panic!("expected String");
        };
        assert_eq!(value.as_slice(), &buf);
    }

    #[test]
    fn decode_entity_key_attribute() {
        let key = B256::repeat_byte(0x77);
        let mut value = [FixedBytes::ZERO; 4];
        value[0] = key;
        let mut op = calldata_op(OP_CREATE);
        op.attributes.push(CalldataAttribute {
            name: ident32("linked.to"),
            valueType: ATTR_ENTITY_KEY,
            value,
        });
        let Operation::Create(c) =
            decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap()
        else {
            unreachable!();
        };
        assert_eq!(
            c.attributes[0],
            Attribute::EntityKey {
                name: Ident32::encode("linked.to").unwrap(),
                value: key,
            },
        );
    }

    #[test]
    fn decode_attribute_rejects_uint_with_nonzero_higher_words() {
        let mut value = u256_word(7);
        value[2] = FixedBytes::repeat_byte(0xFF);
        let mut op = calldata_op(OP_CREATE);
        op.attributes.push(CalldataAttribute {
            name: ident32("bad"),
            valueType: ATTR_UINT,
            value,
        });
        let err = decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event())
            .unwrap_err()
            .to_string();
        assert!(err.contains("data[2]"), "{}", err);
    }

    #[test]
    fn decode_attribute_rejects_unknown_value_type() {
        let mut op = calldata_op(OP_CREATE);
        op.attributes.push(CalldataAttribute {
            name: ident32("unknown"),
            valueType: 99,
            value: [FixedBytes::ZERO; 4],
        });
        let err = decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event())
            .unwrap_err()
            .to_string();
        assert!(err.contains("99"), "{}", err);
    }

    // -------------------------------------------------------------------------
    // Serde JSON shape tests (gated on feature)
    // -------------------------------------------------------------------------

    #[cfg(feature = "serde-wire")]
    #[test]
    fn create_op_json_shape() {
        let mut op = calldata_op(OP_CREATE);
        op.attributes.push(CalldataAttribute {
            name: ident32("priority"),
            valueType: ATTR_UINT,
            value: u256_word(42),
        });
        op.attributes.push(CalldataAttribute {
            name: ident32("title"),
            valueType: ATTR_STRING,
            value: calldata_value(string_buf("note")),
        });
        let decoded = decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap();
        let json = serde_json::to_value(&decoded).unwrap();

        assert_eq!(json["type"], "create");
        assert_eq!(json["opIndex"], 0);
        assert_eq!(json["expiresAt"], "0x4d2"); // 1234 in hex
        assert_eq!(json["payload"], "0x68656c6c6f"); // "hello"
        assert_eq!(json["contentType"], "text/plain");

        let attr0 = &json["attributes"][0];
        assert_eq!(attr0["valueType"], "uint");
        assert_eq!(attr0["name"], "priority");
        assert_eq!(attr0["value"], "0x2a"); // 42 in hex

        // String value is the full 128 bytes (left-aligned "note" + zero
        // padding) as a single hex string — byte-exact, no truncation.
        let attr1 = &json["attributes"][1];
        assert_eq!(attr1["valueType"], "string");
        assert_eq!(attr1["name"], "title");
        let expected = FixedBytes::<128>::from(string_buf("note"));
        assert_eq!(attr1["value"], serde_json::to_value(&expected).unwrap());
    }

    #[cfg(feature = "serde-wire")]
    #[test]
    fn variant_tags_match_v2_spec() {
        for (ty, expected_tag) in [
            (OP_CREATE, "create"),
            (OP_UPDATE, "update"),
            (OP_EXTEND, "extend"),
            (OP_TRANSFER, "transfer"),
            (OP_DELETE, "delete"),
            (OP_EXPIRE, "expire"),
        ] {
            let op = calldata_op(ty);
            let decoded = decode_operation(0, &op, &entity_event(ty), &hash_event()).unwrap();
            let json = serde_json::to_value(&decoded).unwrap();
            assert_eq!(json["type"], expected_tag, "wrong tag for op_type {}", ty);
        }
    }

    #[cfg(feature = "serde-wire")]
    #[test]
    fn entity_key_attribute_json_shape() {
        let key = B256::repeat_byte(0x42);
        let attr = Attribute::EntityKey {
            name: Ident32::encode("linked.to").unwrap(),
            value: key,
        };
        let json = serde_json::to_value(&attr).unwrap();
        assert_eq!(json["valueType"], "entityKey");
        assert_eq!(json["name"], "linked.to");
        assert_eq!(
            json["value"].as_str().unwrap(),
            format!("0x{}", "42".repeat(32))
        );
    }
}
