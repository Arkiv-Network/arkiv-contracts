// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "./BlockNumber.sol";

type OpKey is uint256;
type TxKey is uint256;

/// @title EntityHashing
/// @dev Pure encoding and hashing scheme for the Arkiv EntityRegistry.
///
/// Separated from the stateful EntityRegistry contract so that the encoding
/// scheme can be reviewed, tested, and reused independently. All functions
/// are `internal` and get inlined by the compiler — zero DELEGATECALL overhead.
///
/// The hashing follows EIP-712 structured data conventions: each struct type
/// has a typehash derived from its canonical type string, and dynamic fields
/// (bytes, string, arrays) are keccak256-hashed before encoding.
library EntityHashing {
    // -------------------------------------------------------------------------
    // Type declarations
    // -------------------------------------------------------------------------

    uint8 public constant CREATE = 0;
    uint8 public constant UPDATE = 1;
    uint8 public constant EXTEND = 2;
    uint8 public constant TRANSFER = 3;
    uint8 public constant DELETE = 4;
    uint8 public constant EXPIRE = 5;

    /// @dev Batch element: describes a single entity operation within an
    /// `execute()` call. Fields are interpreted according to `opType`:
    ///   - CREATE:   payload, contentType, attributes, expiresAt
    ///   - UPDATE:   entityKey, payload, contentType, attributes
    ///   - EXTEND:   entityKey, expiresAt
    ///   - TRANSFER: entityKey, newOwner
    ///   - DELETE:   entityKey
    ///   - EXPIRE:   entityKey
    struct Op {
        uint8 opType;
        bytes32 entityKey;
        bytes payload;
        string contentType;
        Attribute[] attributes;
        BlockNumber expiresAt;
        address newOwner;
    }

    /// @dev Discriminator for attribute value types. Encoded into the
    /// attribute hash so that different types with identical raw bytes
    /// produce distinct hashes.
    uint8 public constant ATTR_UINT = 0;
    uint8 public constant ATTR_STRING = 1;
    uint8 public constant ATTR_ENTITY_KEY = 2;

    /// @dev A typed key-value pair attached to an entity. The `name` is a
    /// bytes32-packed UTF-8 identifier (left-aligned, zero-padded).
    /// Attributes must be sorted ascending by name for deterministic hash
    /// computation and name-uniqueness enforcement.
    struct Attribute {
        bytes32 name;
        uint8 valueType;
        bytes value;
    }

    /// @dev On-chain representation of a registered entity. Stored in the
    /// EntityRegistry's entity mapping. The `attributes` array must be
    /// sorted ascending by name to match the ordering enforced at creation.
    struct Entity {
        address creator;
        address owner;
        BlockNumber createdAt;
        BlockNumber updatedAt;
        BlockNumber expiresAt;
        bytes payload;
        string contentType;
        Attribute[] attributes;
    }

    /// @dev Block-level linked list node for traversing mutation history.
    /// Only blocks containing at least one mutation have an entry.
    /// All fields pack into a single slot (20 bytes).
    struct BlockNode {
        uint64 prevBlock;
        uint64 nextBlock;
        uint32 txCount;
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @dev Reverted when `execute()` is called with an empty ops array.
    error EmptyBatch();
    error AttributesNotSorted();
    error InvalidValueLength(bytes32 name, uint8 valueType, uint256 length);
    error InvalidValueType(bytes32 name, uint8 valueType);

    // -------------------------------------------------------------------------
    // Constants — validation limits
    // -------------------------------------------------------------------------

    uint256 internal constant MAX_STRING_ATTR_SIZE = 1024;

    // -------------------------------------------------------------------------
    // Constants — EIP-712 typehashes
    // -------------------------------------------------------------------------

    /// @dev keccak256("Attribute(bytes32 name,uint8 valueType,bytes value)")
    bytes32 internal constant ATTRIBUTE_TYPEHASH = keccak256("Attribute(bytes32 name,uint8 valueType,bytes value)");

    /// @dev keccak256("CoreHash(bytes32 entityKey,address creator,uint32 createdAt,string contentType,bytes payload,bytes32 attributesHash)")
    bytes32 internal constant CORE_HASH_TYPEHASH = keccak256(
        "CoreHash(bytes32 entityKey,address creator,uint32 createdAt,string contentType,bytes payload,bytes32 attributesHash)"
    );

    /// @dev keccak256("EntityHash(bytes32 coreHash,address owner,uint32 updatedAt,uint32 expiresAt)")
    bytes32 internal constant ENTITY_HASH_TYPEHASH =
        keccak256("EntityHash(bytes32 coreHash,address owner,uint32 updatedAt,uint32 expiresAt)");

    // -------------------------------------------------------------------------
    // Hash functions
    // -------------------------------------------------------------------------

    /// @notice Hash a single attribute and chain it onto the rolling hash.
    /// Validates that this attribute's name is strictly greater than the
    /// previous (lexicographic on the packed bytes32), enforcing sorted
    /// order and name uniqueness.
    /// @return The updated rolling hash.
    function attributeHash(bytes32 prevName, bytes32 chain, Attribute calldata attr)
        internal
        pure
        returns (bytes32, bytes32)
    {
        if (attr.name <= prevName) revert AttributesNotSorted();

        uint8 vt = attr.valueType;
        uint256 len = attr.value.length;
        if (vt == ATTR_UINT || vt == ATTR_ENTITY_KEY) {
            if (len != 32) revert InvalidValueLength(attr.name, vt, len);
        } else if (vt == ATTR_STRING) {
            if (len > MAX_STRING_ATTR_SIZE) revert InvalidValueLength(attr.name, vt, len);
        } else {
            revert InvalidValueType(attr.name, vt);
        }

        bytes32 attrHash = keccak256(abi.encode(ATTRIBUTE_TYPEHASH, attr.name, attr.valueType, keccak256(attr.value)));
        return (attr.name, keccak256(abi.encodePacked(chain, attrHash)));
    }

    /// @notice Compute the EIP-712 struct hash of an entity's immutable core
    /// content (everything except owner, updatedAt, expiresAt).
    /// Validates and rolling-hashes the attribute array inline.
    function coreHash(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        string calldata contentType,
        bytes calldata payload,
        Attribute[] calldata attributes
    ) internal pure returns (bytes32) {
        bytes32 attrChain;
        bytes32 prevName;
        for (uint256 i = 0; i < attributes.length; i++) {
            (prevName, attrChain) = attributeHash(prevName, attrChain, attributes[i]);
        }
        return keccak256(
            abi.encode(
                CORE_HASH_TYPEHASH,
                key,
                creator,
                createdAt,
                keccak256(bytes(contentType)),
                keccak256(payload),
                attrChain
            )
        );
    }

    /// @notice Compute the inner EIP-712 struct hash for an entity, without
    /// the domain separator prefix. The caller is responsible for wrapping
    /// this with `_hashTypedDataV4()` to produce the final entity hash.
    /// @param coreHash_ The core content hash (from coreHash()).
    /// @param owner     Current owner address.
    /// @param updatedAt Block number of last update.
    /// @param expiresAt Expiry block number.
    /// @return result The keccak256 EIP-712 struct hash (unwrapped).
    function entityStructHash(bytes32 coreHash_, address owner, BlockNumber updatedAt, BlockNumber expiresAt)
        internal
        pure
        returns (bytes32 result)
    {
        bytes32 th = ENTITY_HASH_TYPEHASH;
        assembly {
            let m := mload(0x40)
            mstore(m, th)
            mstore(add(m, 0x20), coreHash_)
            mstore(add(m, 0x40), owner)
            mstore(add(m, 0x60), updatedAt)
            mstore(add(m, 0x80), expiresAt)
            result := keccak256(m, 0xa0) // 5 × 32 = 160
        }
    }

    /// @notice Derive a globally unique entity key from the chain, registry,
    /// owner, and nonce. Deterministic and collision-resistant across chains
    /// and registry deployments.
    /// @param chainId   The chain ID (typically block.chainid).
    /// @param registry  The registry contract address.
    /// @param owner     The entity owner.
    /// @param nonce     The owner's entity creation nonce.
    /// @return result The keccak256 entity key.
    function entityKey(uint256 chainId, address registry, address owner, uint32 nonce)
        internal
        pure
        returns (bytes32 result)
    {
        // encodePacked layout: chainId (32) | registry (20) | owner (20) | nonce (4) = 76 bytes
        assembly {
            let m := mload(0x40)
            mstore(m, chainId)
            mstore(add(m, 0x20), shl(96, registry))
            mstore(add(m, 0x34), shl(96, owner))
            mstore(add(m, 0x48), shl(224, nonce))
            result := keccak256(m, 76)
        }
    }

    /// @notice Compute the next changeset hash by chaining an operation onto
    /// the previous hash. The changeset is an append-only hash chain where
    /// each link encodes the operation type, entity key, and resulting
    /// entity hash.
    /// @param prev        The changeset hash before this operation.
    /// @param opType      The operation type being recorded.
    /// @param key         The entity key affected.
    /// @param entityHash_ The entity hash after the operation.
    /// @return result The new changeset hash.
    function chainOp(bytes32 prev, uint8 opType, bytes32 key, bytes32 entityHash_)
        internal
        pure
        returns (bytes32 result)
    {
        // encodePacked layout: prev (32) | opType (1) | key (32) | entityHash_ (32) = 97 bytes
        assembly {
            let m := mload(0x40)
            mstore(m, prev)
            mstore8(add(m, 0x20), opType)
            mstore(add(m, 0x21), key)
            mstore(add(m, 0x41), entityHash_)
            result := keccak256(m, 97)
        }
    }

    // -------------------------------------------------------------------------
    // Storage key packing
    // -------------------------------------------------------------------------

    /// @notice Pack a (block, tx) pair into a TxKey for the `_txOpCount`
    /// mapping. Layout: block in bits [32..95], tx in bits [0..31].
    function txKey(uint256 blockNumber, uint32 txSeq) internal pure returns (TxKey) {
        return TxKey.wrap((blockNumber << 32) | txSeq);
    }

    /// @notice Pack a (block, tx, op) triple into an OpKey for the `_hashAt`
    /// mapping. Layout: block in bits [64..127], tx in bits [32..63], op in
    /// bits [0..31]. Extends txKey with the op dimension.
    function opKey(uint256 blockNumber, uint32 txSeq, uint32 opSeq) internal pure returns (OpKey) {
        return OpKey.wrap((TxKey.unwrap(txKey(blockNumber, txSeq)) << 32) | opSeq);
    }
}
