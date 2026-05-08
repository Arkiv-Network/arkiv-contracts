//! Wire-format types for the v2 ExEx → EntityDB JSON-RPC interface
//! (`arkiv-op-reth/docs/exex-jsonrpc-interface-v2.md`).
//!
//! # Type hierarchy
//!
//! ```text
//! ArkivBlock
//!   └─ ArkivBlockHeader       (block number, hash, changeset hash)
//!   └─ ArkivTransaction[]
//!        └─ ArkivOperation[]  (tagged by op type)
//!             └─ ArkivAttribute[] (on create / update)
//! ```
//!
//! [`ArkivOperation`] and [`ArkivAttribute`] are the decoded, validated
//! representations of the raw ABI [`Operation`] / [`Attribute`] calldata
//! structs. Block and transaction envelopes are defined here so that all
//! wire-format shapes live in one place; consumers build them from
//! reth-specific inputs (`RecoveredBlock`, signature recovery, etc.) and
//! forward the complete [`ArkivBlock`] to the EntityDB.
//!
//! [`Operation`]: crate::Operation
//! [`Attribute`]: crate::Attribute
//!
//! # Decoding
//!
//! [`decode_operation`] pairs one raw calldata [`Operation`] with its two
//! emitted events (`EntityOperation` and `ChangeSetHashUpdate`) to produce
//! an [`ArkivOperation`]. It validates [`Mime128`] content types and
//! [`Ident32`] attribute names on the way in.
//!
//! `expires_at` on [`CreateOp`] and [`ExtendOp`] is sourced from
//! `EntityOperation.expiresAt` — the absolute block number the contract
//! computed as `currentBlock + op.btl`. The raw `btl` is not exposed.
//!
//! `ATTR_STRING` values are `FixedBytes<128>` — the protocol treats those
//! 128 bytes as opaque; UTF-8 interpretation is the consumer's choice.
//!
//! Serde annotations are gated behind the `serde-wire` feature (default on).

use alloy_primitives::{Address, B256, Bytes, FixedBytes, U256};
use eyre::{Result, bail};

#[cfg(feature = "serde-wire")]
use serde::Serialize;

use crate::IEntityRegistry::{ChangeSetHashUpdate, EntityOperation};
use crate::{
    ATTR_ENTITY_KEY, ATTR_STRING, ATTR_UINT, Attribute, Ident32, Mime128, OP_CREATE, OP_DELETE,
    OP_EXPIRE, OP_EXTEND, OP_TRANSFER, OP_UPDATE, Operation,
};

// -----------------------------------------------------------------------------
// Block / transaction envelopes
// -----------------------------------------------------------------------------

/// Block header subset forwarded to the EntityDB.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(rename_all = "camelCase"))]
pub struct ArkivBlockHeader {
    #[cfg_attr(feature = "serde-wire", serde(with = "hex_u64"))]
    pub number: u64,
    pub hash: B256,
    pub parent_hash: B256,
    /// Rolling changeset hash as of the end of this block. `B256::ZERO` only
    /// when no operation has ever been recorded at or before this block.
    pub changeset_hash: B256,
}

/// A block with its decoded Arkiv transactions (may be empty).
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
pub struct ArkivBlock {
    pub header: ArkivBlockHeader,
    pub transactions: Vec<ArkivTransaction>,
}

/// A transaction targeting the EntityRegistry with decoded operations.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(rename_all = "camelCase"))]
pub struct ArkivTransaction {
    pub hash: B256,
    pub index: u32,
    pub sender: Address,
    pub operations: Vec<ArkivOperation>,
}

/// Minimal block identifier for revert payloads.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(rename_all = "camelCase"))]
pub struct ArkivBlockRef {
    #[cfg_attr(feature = "serde-wire", serde(with = "hex_u64"))]
    pub number: u64,
    pub hash: B256,
}

// -----------------------------------------------------------------------------
// ArkivOperation — decoded, validated, tagged by op type
// -----------------------------------------------------------------------------

/// A decoded EntityRegistry operation.
///
/// JSON shape: `{"type": "create" | "update" | …, …fields}`.
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(feature = "serde-wire", serde(tag = "type", rename_all = "camelCase"))]
pub enum ArkivOperation {
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
    pub content_type: Mime128,
    pub attributes: Vec<ArkivAttribute>,
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
    pub content_type: Mime128,
    pub attributes: Vec<ArkivAttribute>,
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
// ArkivAttribute — validated, typed attribute value
// -----------------------------------------------------------------------------

/// A typed attribute decoded from the on-chain `Attribute { name, valueType,
/// value }` shape.
///
/// - `Uint`      — `U256` (right-aligned in `data[0]` on-chain)
/// - `String`    — `FixedBytes<128>` (full `bytes32[4]`, byte-exact and opaque)
/// - `EntityKey` — `B256` (`data[0]` on-chain)
#[derive(Debug, Clone, PartialEq, Eq)]
#[cfg_attr(feature = "serde-wire", derive(Serialize))]
#[cfg_attr(
    feature = "serde-wire",
    serde(tag = "valueType", rename_all = "camelCase")
)]
pub enum ArkivAttribute {
    Uint { name: Ident32, value: U256 },
    String { name: Ident32, value: FixedBytes<128> },
    EntityKey { name: Ident32, value: B256 },
}

// -----------------------------------------------------------------------------
// Decoder
// -----------------------------------------------------------------------------

/// Build a typed [`ArkivOperation`] from a single decoded calldata op plus
/// the two paired event records (`EntityOperation` and `ChangeSetHashUpdate`).
///
/// - `op_index`: position within the transaction's `ops[]`
/// - `calldata`: the [`Operation`] struct from `executeCall::abi_decode`
/// - `entity_event`: the `EntityOperation` event emitted for this op
/// - `hash_event`: the `ChangeSetHashUpdate` event emitted for this op
///
/// Errors if operationType mismatches, the op type is unknown, the
/// `Mime128` content type is invalid, or any attribute name fails
/// `Ident32` validation.
pub fn decode_operation(
    op_index: u32,
    calldata: &Operation,
    entity_event: &EntityOperation,
    hash_event: &ChangeSetHashUpdate,
) -> Result<ArkivOperation> {
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
    // expiresAt is u32 in the event struct (alloy uses the underlying RustType).
    let expires_at = u64::from(entity_event.expiresAt);

    Ok(match calldata.operationType {
        OP_CREATE => ArkivOperation::Create(CreateOp {
            op_index,
            entity_key,
            owner,
            expires_at,
            entity_hash,
            changeset_hash,
            payload: calldata.payload.clone(),
            content_type: calldata.contentType.clone().validate()?,
            attributes: decode_attributes(&calldata.attributes)?,
        }),
        OP_UPDATE => ArkivOperation::Update(UpdateOp {
            op_index,
            entity_key,
            owner,
            entity_hash,
            changeset_hash,
            payload: calldata.payload.clone(),
            content_type: calldata.contentType.clone().validate()?,
            attributes: decode_attributes(&calldata.attributes)?,
        }),
        OP_EXTEND => ArkivOperation::Extend(ExtendOp {
            op_index,
            entity_key,
            owner,
            expires_at,
            entity_hash,
            changeset_hash,
        }),
        OP_TRANSFER => ArkivOperation::Transfer(TransferOp {
            op_index,
            entity_key,
            owner,
            entity_hash,
            changeset_hash,
        }),
        OP_DELETE => ArkivOperation::Delete(DeleteOp {
            op_index,
            entity_key,
            owner,
            entity_hash,
            changeset_hash,
        }),
        OP_EXPIRE => ArkivOperation::Expire(ExpireOp {
            op_index,
            entity_key,
            owner,
            entity_hash,
            changeset_hash,
        }),
        other => bail!("unknown operation type: {}", other),
    })
}

fn decode_attributes(attrs: &[Attribute]) -> Result<Vec<ArkivAttribute>> {
    attrs.iter().map(decode_attribute).collect()
}

fn decode_attribute(attr: &Attribute) -> Result<ArkivAttribute> {
    // attr.name is FixedBytes<32> — alloy unwraps UDVTs to primitives in
    // struct fields. Wrap into Ident32 and validate charset + null-termination.
    let name = Ident32(attr.name).validate()?;

    match attr.valueType {
        ATTR_UINT => {
            require_single_word(&attr.value, attr.valueType)?;
            Ok(ArkivAttribute::Uint {
                name,
                value: U256::from_be_bytes(attr.value[0].0),
            })
        }
        ATTR_STRING => {
            let mut buf = [0u8; 128];
            for (i, w) in attr.value.iter().enumerate() {
                buf[i * 32..(i + 1) * 32].copy_from_slice(w.as_slice());
            }
            Ok(ArkivAttribute::String {
                name,
                value: FixedBytes::from(buf),
            })
        }
        ATTR_ENTITY_KEY => {
            require_single_word(&attr.value, attr.valueType)?;
            Ok(ArkivAttribute::EntityKey {
                name,
                value: attr.value[0],
            })
        }
        other => bail!("unknown attribute value_type: {}", other),
    }
}

/// Enforce the bytes32-sized invariant for UINT and ENTITY_KEY:
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
// Hex u64 serializer — block numbers and expiry as JSON hex strings ("0x…").
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

    fn ident32(name: &str) -> FixedBytes<32> {
        let mut bytes = [0u8; 32];
        bytes[..name.len()].copy_from_slice(name.as_bytes());
        FixedBytes::from(bytes)
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

    fn calldata_value(buf: [u8; 128]) -> [FixedBytes<32>; 4] {
        let mut data = [FixedBytes::ZERO; 4];
        for (i, w) in data.iter_mut().enumerate() {
            *w = FixedBytes::from_slice(&buf[i * 32..(i + 1) * 32]);
        }
        data
    }

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
            expiresAt: 1234u32,
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

    fn raw_op(op_type: u8) -> Operation {
        Operation {
            operationType: op_type,
            entityKey: B256::ZERO,
            payload: Bytes::from_static(b"hello"),
            contentType: mime128("text/plain"),
            attributes: vec![],
            btl: 1234u32,
            newOwner: Address::ZERO,
        }
    }

    #[test]
    fn decode_create_populates_body_fields() {
        let op = raw_op(OP_CREATE);
        let decoded = decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap();
        let ArkivOperation::Create(c) = decoded else {
            panic!("expected Create variant");
        };
        assert_eq!(c.op_index, 0);
        assert_eq!(c.entity_key, B256::repeat_byte(0xE1));
        assert_eq!(c.owner, Address::repeat_byte(0xAA));
        assert_eq!(c.expires_at, 1234);
        assert_eq!(c.entity_hash, B256::repeat_byte(0xE2));
        assert_eq!(c.changeset_hash, B256::repeat_byte(0xC1));
        assert_eq!(c.payload, Bytes::from_static(b"hello"));
        assert_eq!(c.content_type.as_str().unwrap(), "text/plain");
        assert!(c.attributes.is_empty());
    }

    #[test]
    fn decode_fails_on_invalid_mime_content_type() {
        let mut op = raw_op(OP_CREATE);
        op.contentType = mime128("text");
        let err = decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event())
            .unwrap_err()
            .to_string();
        assert!(err.contains("MIME"), "{}", err);
    }

    #[test]
    fn decode_fails_on_invalid_ident32_attribute_name() {
        let mut op = raw_op(OP_CREATE);
        let mut name_bytes = [0u8; 32];
        name_bytes[..5].copy_from_slice(b"UPPER");
        op.attributes.push(Attribute {
            name: FixedBytes::from(name_bytes),
            valueType: ATTR_UINT,
            value: u256_word(1),
        });
        let err = decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event())
            .unwrap_err()
            .to_string();
        assert!(err.contains("Ident32"), "{}", err);
    }

    #[test]
    fn decode_update_omits_expires_at() {
        let op = raw_op(OP_UPDATE);
        let decoded = decode_operation(3, &op, &entity_event(OP_UPDATE), &hash_event()).unwrap();
        let ArkivOperation::Update(u) = decoded else {
            panic!("expected Update");
        };
        assert_eq!(u.op_index, 3);
        assert_eq!(u.payload, Bytes::from_static(b"hello"));
    }

    #[test]
    fn decode_extend_carries_expires_at_no_body() {
        let op = raw_op(OP_EXTEND);
        let decoded = decode_operation(1, &op, &entity_event(OP_EXTEND), &hash_event()).unwrap();
        let ArkivOperation::Extend(e) = decoded else {
            panic!("expected Extend");
        };
        assert_eq!(e.expires_at, 1234);
    }

    #[test]
    fn decode_transfer_delete_expire_have_no_body() {
        for ty in [OP_TRANSFER, OP_DELETE, OP_EXPIRE] {
            let op = raw_op(ty);
            let decoded = decode_operation(0, &op, &entity_event(ty), &hash_event()).unwrap();
            match (ty, &decoded) {
                (OP_TRANSFER, ArkivOperation::Transfer(_)) => {}
                (OP_DELETE, ArkivOperation::Delete(_)) => {}
                (OP_EXPIRE, ArkivOperation::Expire(_)) => {}
                _ => panic!("variant mismatch for op_type {}: {:?}", ty, decoded),
            }
        }
    }

    #[test]
    fn decode_rejects_event_calldata_mismatch() {
        let op = raw_op(OP_CREATE);
        let err = decode_operation(0, &op, &entity_event(OP_DELETE), &hash_event())
            .unwrap_err()
            .to_string();
        assert!(err.contains("operationType mismatch"), "{}", err);
    }

    #[test]
    fn decode_rejects_unknown_op_type() {
        let mut op = raw_op(OP_CREATE);
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
        let mut op = raw_op(OP_CREATE);
        op.attributes.push(Attribute {
            name: ident32("count"),
            valueType: ATTR_UINT,
            value: u256_word(42),
        });
        let ArkivOperation::Create(c) =
            decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap()
        else {
            unreachable!();
        };
        assert_eq!(c.attributes.len(), 1);
        assert_eq!(
            c.attributes[0],
            ArkivAttribute::Uint {
                name: Ident32::encode("count").unwrap(),
                value: U256::from(42u64),
            },
        );
    }

    #[test]
    fn decode_string_attribute_byte_exact() {
        let buf = string_buf("hello");
        let mut op = raw_op(OP_CREATE);
        op.attributes.push(Attribute {
            name: ident32("title"),
            valueType: ATTR_STRING,
            value: calldata_value(buf),
        });
        let ArkivOperation::Create(c) =
            decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap()
        else {
            unreachable!();
        };
        assert_eq!(
            c.attributes[0],
            ArkivAttribute::String {
                name: Ident32::encode("title").unwrap(),
                value: FixedBytes::from(buf),
            },
        );
    }

    #[test]
    fn decode_string_attribute_preserves_arbitrary_bytes() {
        let mut buf = [0u8; 128];
        buf[0] = 0xFF;
        buf[1] = 0xFE;
        buf[10] = 0x00;
        buf[20] = b'x';
        buf[127] = 0xAA;
        let mut op = raw_op(OP_CREATE);
        op.attributes.push(Attribute {
            name: ident32("garbage"),
            valueType: ATTR_STRING,
            value: calldata_value(buf),
        });
        let ArkivOperation::Create(c) =
            decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap()
        else {
            unreachable!();
        };
        let ArkivAttribute::String { value, .. } = &c.attributes[0] else {
            panic!("expected String");
        };
        assert_eq!(value.as_slice(), &buf);
    }

    #[test]
    fn decode_entity_key_attribute() {
        let key = B256::repeat_byte(0x77);
        let mut value = [FixedBytes::ZERO; 4];
        value[0] = key;
        let mut op = raw_op(OP_CREATE);
        op.attributes.push(Attribute {
            name: ident32("linked.to"),
            valueType: ATTR_ENTITY_KEY,
            value,
        });
        let ArkivOperation::Create(c) =
            decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap()
        else {
            unreachable!();
        };
        assert_eq!(
            c.attributes[0],
            ArkivAttribute::EntityKey {
                name: Ident32::encode("linked.to").unwrap(),
                value: key,
            },
        );
    }

    #[test]
    fn decode_attribute_rejects_uint_with_nonzero_higher_words() {
        let mut value = u256_word(7);
        value[2] = FixedBytes::repeat_byte(0xFF);
        let mut op = raw_op(OP_CREATE);
        op.attributes.push(Attribute {
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
        let mut op = raw_op(OP_CREATE);
        op.attributes.push(Attribute {
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
    // Serde JSON shape tests
    // -------------------------------------------------------------------------

    #[cfg(feature = "serde-wire")]
    #[test]
    fn create_op_json_shape() {
        let mut op = raw_op(OP_CREATE);
        op.attributes.push(Attribute {
            name: ident32("priority"),
            valueType: ATTR_UINT,
            value: u256_word(42),
        });
        op.attributes.push(Attribute {
            name: ident32("title"),
            valueType: ATTR_STRING,
            value: calldata_value(string_buf("note")),
        });
        let decoded = decode_operation(0, &op, &entity_event(OP_CREATE), &hash_event()).unwrap();
        let json = serde_json::to_value(&decoded).unwrap();

        assert_eq!(json["type"], "create");
        assert_eq!(json["opIndex"], 0);
        assert_eq!(json["expiresAt"], "0x4d2");
        assert_eq!(json["payload"], "0x68656c6c6f");
        assert_eq!(json["contentType"], "text/plain");

        let attr0 = &json["attributes"][0];
        assert_eq!(attr0["valueType"], "uint");
        assert_eq!(attr0["name"], "priority");
        assert_eq!(attr0["value"], "0x2a");

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
            let op = raw_op(ty);
            let decoded = decode_operation(0, &op, &entity_event(ty), &hash_event()).unwrap();
            let json = serde_json::to_value(&decoded).unwrap();
            assert_eq!(json["type"], expected_tag, "wrong tag for op_type {}", ty);
        }
    }

    #[cfg(feature = "serde-wire")]
    #[test]
    fn entity_key_attribute_json_shape() {
        let key = B256::repeat_byte(0x42);
        let attr = ArkivAttribute::EntityKey {
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
