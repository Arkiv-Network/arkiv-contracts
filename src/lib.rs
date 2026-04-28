pub mod decode;
pub mod storage_layout;
pub mod types;

// Generated from IEntityRegistry.sol ABI by build.rs.
// Contains struct definitions (Operation, Attribute, Mime128, Commitment, BlockNode)
// and the IEntityRegistry interface with all functions, events, and errors.
include!(concat!(env!("OUT_DIR"), "/sol.rs"));

// EntityRegistry creation bytecode embedded at build time.
include!(concat!(env!("OUT_DIR"), "/bytecode.rs"));

/// Operation type constants (mirrors Entity.sol).
pub const OP_CREATE: u8 = 1;
pub const OP_UPDATE: u8 = 2;
pub const OP_EXTEND: u8 = 3;
pub const OP_TRANSFER: u8 = 4;
pub const OP_DELETE: u8 = 5;
pub const OP_EXPIRE: u8 = 6;

/// Attribute value type constants (mirrors Entity.sol).
pub const ATTR_UINT: u8 = 1;
pub const ATTR_STRING: u8 = 2;
pub const ATTR_ENTITY_KEY: u8 = 3;

/// Maximum number of attributes per entity operation (mirrors Entity.sol's
/// internal `MAX_ATTRIBUTES`). The contract reverts `TooManyAttributes` past
/// this count; SDKs can validate locally before sending a transaction.
pub const MAX_ATTRIBUTES: usize = 32;

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{Address, B256, Bytes, FixedBytes, U256};
    use alloy_sol_types::{SolCall, SolEvent, SolValue};

    #[test]
    fn execute_selector_matches() {
        // Verified from Foundry output: 0xba8ccf92
        assert_eq!(
            IEntityRegistry::executeCall::SELECTOR,
            [0xba, 0x8c, 0xcf, 0x92]
        );
    }

    #[test]
    fn operation_encode_decode_roundtrip() {
        let op = Operation {
            operationType: OP_CREATE,
            entityKey: B256::ZERO,
            payload: Bytes::from_static(&[0xde, 0xad]),
            contentType: Mime128 {
                data: [FixedBytes::ZERO; 4],
            },
            attributes: vec![],
            expiresAt: 1000,
            newOwner: Address::ZERO,
        };

        let encoded = IEntityRegistry::executeCall {
            ops: vec![op.clone()],
        }
        .abi_encode();
        let decoded = IEntityRegistry::executeCall::abi_decode(&encoded).expect("decode failed");
        assert_eq!(decoded.ops.len(), 1);
        assert_eq!(decoded.ops[0], op);
    }

    #[test]
    fn operation_with_attributes_roundtrip() {
        let name = types::Ident32::encode("status").unwrap();
        let mut value = [FixedBytes::ZERO; 4];
        value[0] = B256::from(U256::from(42));

        let attr = Attribute {
            name: name.as_b256().into(),
            valueType: ATTR_UINT,
            value,
        };

        let op = Operation {
            operationType: OP_CREATE,
            entityKey: B256::ZERO,
            payload: Bytes::from_static(b"hello"),
            contentType: Mime128 {
                data: [FixedBytes::ZERO; 4],
            },
            attributes: vec![attr.clone()],
            expiresAt: 500,
            newOwner: Address::ZERO,
        };

        let encoded = IEntityRegistry::executeCall {
            ops: vec![op.clone()],
        }
        .abi_encode();
        let decoded = IEntityRegistry::executeCall::abi_decode(&encoded).expect("decode failed");
        assert_eq!(decoded.ops[0].attributes.len(), 1);
        assert_eq!(decoded.ops[0].attributes[0], attr);
    }

    #[test]
    fn entity_operation_event_roundtrip() {
        let event = IEntityRegistry::EntityOperation {
            entityKey: B256::repeat_byte(0x01),
            operationType: OP_CREATE,
            owner: Address::repeat_byte(0xAA),
            expiresAt: 1000,
            entityHash: B256::repeat_byte(0x02),
        };

        let log = event.encode_log_data();
        assert_eq!(log.topics().len(), 4);

        let decoded =
            IEntityRegistry::EntityOperation::decode_log_data(&log).expect("decode failed");
        assert_eq!(decoded.entityKey, B256::repeat_byte(0x01));
        assert_eq!(decoded.operationType, OP_CREATE);
        assert_eq!(decoded.owner, Address::repeat_byte(0xAA));
        assert_eq!(decoded.expiresAt, 1000);
    }

    #[test]
    fn changeset_hash_update_event_roundtrip() {
        let event = IEntityRegistry::ChangeSetHashUpdate {
            entityKey: B256::repeat_byte(0x01),
            operationKey: U256::from(0xAABBCCu64),
            changeSetHash: B256::repeat_byte(0x02),
        };

        let log = event.encode_log_data();
        assert_eq!(log.topics().len(), 3); // selector + 2 indexed

        let decoded =
            IEntityRegistry::ChangeSetHashUpdate::decode_log_data(&log).expect("decode failed");
        assert_eq!(decoded.entityKey, B256::repeat_byte(0x01));
        assert_eq!(decoded.operationKey, U256::from(0xAABBCCu64));
        assert_eq!(decoded.changeSetHash, B256::repeat_byte(0x02));
    }

    #[test]
    fn commitment_roundtrip() {
        let c = Commitment {
            creator: Address::repeat_byte(0x01),
            createdAt: 100,
            updatedAt: 200,
            expiresAt: 300,
            owner: Address::repeat_byte(0x02),
            coreHash: B256::repeat_byte(0xAA),
        };

        let encoded = c.abi_encode();
        let decoded = Commitment::abi_decode(&encoded).expect("decode failed");
        assert_eq!(decoded, c);
    }

    #[test]
    fn ident32_encode_validates() {
        assert!(types::Ident32::encode("valid.name").is_ok());
        assert!(types::Ident32::encode("").is_err());
        assert!(types::Ident32::encode("UPPER").is_err());
        assert!(types::Ident32::encode("1digit").is_err());
    }

    #[test]
    fn mime128_encode_validates() {
        assert!(types::Mime128Str::encode("application/json").is_ok());
        assert!(types::Mime128Str::encode("text/plain; charset=utf-8").is_ok());
        assert!(types::Mime128Str::encode("").is_err());
        assert!(types::Mime128Str::encode("Application/JSON").is_err());
        assert!(types::Mime128Str::encode("text").is_err());
    }

    #[test]
    fn mime128_encode_produces_valid_abi_data() {
        let m = types::Mime128Str::encode("application/json").unwrap();
        let raw = m.to_bytes32x4();
        let decoded = types::Mime128Str::decode(&raw).unwrap();
        assert_eq!(decoded, "application/json");

        // Also works with the sol!-generated Mime128 type
        let mime = Mime128 { data: raw };
        let decoded2 = decode::decode_mime128(&mime).unwrap();
        assert_eq!(decoded2, "application/json");
    }

    #[test]
    fn bytecode_is_embedded() {
        assert!(!ENTITY_REGISTRY_CREATION_CODE.is_empty());
    }

    #[test]
    fn op_type_names() {
        assert_eq!(types::op_type_name(OP_CREATE), "CREATE");
        assert_eq!(types::op_type_name(OP_EXPIRE), "EXPIRE");
        assert_eq!(types::op_type_name(0), "UNKNOWN");
    }

    #[test]
    fn operation_type_constants() {
        assert_eq!(OP_CREATE, 1);
        assert_eq!(OP_UPDATE, 2);
        assert_eq!(OP_EXTEND, 3);
        assert_eq!(OP_TRANSFER, 4);
        assert_eq!(OP_DELETE, 5);
        assert_eq!(OP_EXPIRE, 6);
    }
}
