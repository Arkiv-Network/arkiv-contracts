use alloy_primitives::{address, Address};
use alloy_sol_types::sol;

/// Predeploy address for the EntityRegistry in genesis.
pub const ENTITY_REGISTRY_ADDRESS: Address =
    address!("0x4200000000000000000000000000000000000042");

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

sol! {
    /// 128-byte MIME type container (4 x bytes32).
    /// Maps to `struct Mime128 { bytes32[4] data; }` in Solidity.
    #[derive(Debug, Default, PartialEq, Eq)]
    struct Mime128 {
        bytes32[4] data;
    }

    /// Typed key-value attribute attached to an entity.
    /// Maps to `struct Entity.Attribute` in Solidity.
    ///   - name: validated Ident32 (bytes32 UDVT)
    ///   - valueType: 1=UINT, 2=STRING, 3=ENTITY_KEY
    ///   - value: 128-byte fixed container (4 x bytes32)
    #[derive(Debug, Default, PartialEq, Eq)]
    struct Attribute {
        bytes32 name;
        uint8 valueType;
        bytes32[4] value;
    }

    /// Batch element for `execute()`. Fields are interpreted per operationType.
    /// Maps to `struct Entity.Operation` in Solidity.
    #[derive(Debug, Default, PartialEq, Eq)]
    struct Operation {
        uint8 operationType;
        bytes32 entityKey;
        bytes payload;
        Mime128 contentType;
        Attribute[] attributes;
        uint32 expiresAt;
        address newOwner;
    }

    /// On-chain entity commitment returned by `commitment(bytes32)`.
    /// Maps to `struct Entity.Commitment` in Solidity.
    #[derive(Debug, Default, PartialEq, Eq)]
    struct Commitment {
        address creator;
        uint32 createdAt;
        uint32 updatedAt;
        uint32 expiresAt;
        address owner;
        bytes32 coreHash;
    }

    /// Block-level linked list node returned by `getBlockNode(uint32)`.
    #[derive(Debug, Default, PartialEq, Eq)]
    struct BlockNode {
        uint32 prevBlock;
        uint32 nextBlock;
        uint32 txCount;
    }

    /// EntityRegistry contract interface.
    #[sol(rpc)]
    interface IEntityRegistry {
        // ── Events ──────────────────────────────────────────────

        event EntityOperation(
            bytes32 indexed entityKey,
            uint8   indexed operationType,
            address indexed owner,
            uint32  expiresAt,
            bytes32 entityHash
        );

        // ── Write ───────────────────────────────────────────────

        function execute(Operation[] calldata ops) external;

        // ── Read ────────────────────────────────────────────────

        function changeSetHash() external view returns (bytes32);
        function changeSetHashAtBlock(uint32 blockNumber) external view returns (bytes32);
        function changeSetHashAtTx(uint32 blockNumber, uint32 txSeq) external view returns (bytes32);
        function changeSetHashAtOp(uint32 blockNumber, uint32 txSeq, uint32 opSeq) external view returns (bytes32);
        function commitment(bytes32 key) external view returns (Commitment memory);
        function entityKey(address owner, uint32 nonce) external view returns (bytes32);
        function genesisBlock() external view returns (uint32);
        function headBlock() external view returns (uint32);
        function getBlockNode(uint32 blockNumber) external view returns (BlockNode memory);
        function nonces(address owner) external view returns (uint32);
        function txOpCount(uint32 blockNumber, uint32 txSeq) external view returns (uint32);
    }
}

/// Re-export generated types at crate root for convenience.
pub use Mime128 as Mime128Type;
pub use Attribute as AttributeType;
pub use Operation as OperationType;
pub use Commitment as CommitmentType;
pub use BlockNode as BlockNodeType;
pub use IEntityRegistry::*;

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{b256, Address, Bytes, B256, FixedBytes, U256};
    use alloy_sol_types::{SolCall, SolEvent, SolValue};

    #[test]
    fn execute_selector_matches_foundry_output() {
        // Verified from out/EntityRegistry.sol/EntityRegistry.json:
        //   "execute((uint8,bytes32,bytes,(bytes32[4]),(bytes32,uint8,bytes32[4])[],uint32,address)[])"
        //   => 0xba8ccf92
        assert_eq!(executeCall::SELECTOR, [0xba, 0x8c, 0xcf, 0x92]);
    }

    #[test]
    fn encode_decode_operation_roundtrip() {
        let op = Operation {
            operationType: OP_CREATE,
            entityKey: B256::ZERO,
            payload: Bytes::from_static(&[0xde, 0xad, 0xbe, 0xef]),
            contentType: Mime128 {
                data: [FixedBytes::ZERO; 4],
            },
            attributes: vec![],
            expiresAt: 1000,
            newOwner: Address::ZERO,
        };

        let encoded = executeCall { ops: vec![op.clone()] }.abi_encode();
        let decoded = executeCall::abi_decode(&encoded).expect("decode failed");
        assert_eq!(decoded.ops.len(), 1);
        assert_eq!(decoded.ops[0], op);
    }

    #[test]
    fn encode_decode_operation_with_attributes() {
        let mut name_bytes = [0u8; 32];
        name_bytes[..4].copy_from_slice(b"test");
        let name = FixedBytes::from(name_bytes);

        let mut value = [FixedBytes::ZERO; 4];
        value[0] = B256::from(U256::from(42));

        let attr = Attribute {
            name,
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

        let encoded = executeCall { ops: vec![op.clone()] }.abi_encode();
        let decoded = executeCall::abi_decode(&encoded).expect("decode failed");
        assert_eq!(decoded.ops[0].attributes.len(), 1);
        assert_eq!(decoded.ops[0].attributes[0], attr);
    }

    #[test]
    fn decode_entity_operation_event_log() {
        // Build a synthetic log matching the EntityOperation event signature
        let entity_key = b256!("0000000000000000000000000000000000000000000000000000000000000001");
        let owner = Address::repeat_byte(0xAA);

        let event = IEntityRegistry::EntityOperation {
            entityKey: entity_key,
            operationType: OP_CREATE,
            owner,
            expiresAt: 1000,
            entityHash: b256!("0000000000000000000000000000000000000000000000000000000000000002"),
        };

        let log = event.encode_log_data();
        assert_eq!(log.topics().len(), 4); // event sig + 3 indexed

        // Decode back
        let decoded = IEntityRegistry::EntityOperation::decode_log_data(&log)
            .expect("decode failed");
        assert_eq!(decoded.entityKey, entity_key);
        assert_eq!(decoded.operationType, OP_CREATE);
        assert_eq!(decoded.owner, owner);
        assert_eq!(decoded.expiresAt, 1000);
    }

    #[test]
    fn commitment_abi_roundtrip() {
        let c = Commitment {
            creator: Address::repeat_byte(0x01),
            createdAt: 100,
            updatedAt: 200,
            expiresAt: 300,
            owner: Address::repeat_byte(0x02),
            coreHash: b256!("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
        };

        let encoded = c.abi_encode();
        let decoded = Commitment::abi_decode(&encoded).expect("decode failed");
        assert_eq!(decoded, c);
    }

    #[test]
    fn operation_type_constants_are_correct() {
        assert_eq!(OP_CREATE, 1);
        assert_eq!(OP_UPDATE, 2);
        assert_eq!(OP_EXTEND, 3);
        assert_eq!(OP_TRANSFER, 4);
        assert_eq!(OP_DELETE, 5);
        assert_eq!(OP_EXPIRE, 6);
    }

    #[test]
    fn predeploy_address_is_correct() {
        assert_eq!(
            ENTITY_REGISTRY_ADDRESS,
            "0x4200000000000000000000000000000000000042"
                .parse::<Address>()
                .unwrap()
        );
    }
}
