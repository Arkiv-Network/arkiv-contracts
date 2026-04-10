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

    /// @dev On-chain entity commitment. Stores only the fields needed to
    /// recompute entityHash from chain state alone — no payload or attributes.
    /// Full entity data lives in calldata/events for the off-chain DB.
    ///
    /// Storage layout (3 slots):
    ///   slot 0: creator (20) | createdAt (4) | updatedAt (4) | expiresAt (4) = 32 bytes
    ///   slot 1: owner (20) | [12 bytes padding]
    ///   slot 2: coreHash (32)
    struct Commitment {
        address creator;
        BlockNumber createdAt;
        BlockNumber updatedAt;
        BlockNumber expiresAt;
        address owner;
        bytes32 coreHash;
    }

    /// @dev Block-level linked list node for traversing mutation history.
    /// Only blocks containing at least one mutation have an entry.
    /// All fields pack into a single slot (12 bytes).
    struct BlockNode {
        BlockNumber prevBlock;
        BlockNumber nextBlock;
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
    error ExpiryInPast(BlockNumber expiresAt, BlockNumber currentBlock);
    error TooManyAttributes(uint256 count, uint256 maxCount);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant MAX_ATTRIBUTES = 32;
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
    /// @return The keccak256 EIP-712 struct hash (unwrapped).
    function entityStructHash(bytes32 coreHash_, address owner, BlockNumber updatedAt, BlockNumber expiresAt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(ENTITY_HASH_TYPEHASH, coreHash_, owner, updatedAt, expiresAt));
    }

    /// @notice Derive a globally unique entity key from the chain, registry,
    /// owner, and nonce. Deterministic and collision-resistant across chains
    /// and registry deployments.
    function entityKey(uint256 chainId, address registry, address owner, uint32 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(chainId, registry, owner, nonce));
    }

    /// @notice Compute the next changeset hash by chaining an operation onto
    /// the previous hash. The changeset is an append-only hash chain where
    /// each link encodes the operation type, entity key, and resulting
    /// entity hash.
    function chainOp(bytes32 prev, uint8 opType, bytes32 key, bytes32 entityHash_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, opType, key, entityHash_));
    }

    // -------------------------------------------------------------------------
    // Storage key packing
    // -------------------------------------------------------------------------

    /// @notice Pack a (block, tx) pair into a TxKey for the `_txOpCount`
    /// mapping. Layout: block in bits [32..95], tx in bits [0..31].
    function txKey(BlockNumber blockNumber, uint32 txSeq) internal pure returns (TxKey) {
        return TxKey.wrap((uint256(BlockNumber.unwrap(blockNumber)) << 32) | txSeq);
    }

    /// @notice Pack a (block, tx, op) triple into an OpKey for the `_hashAt`
    /// mapping. Layout: block in bits [64..127], tx in bits [32..63], op in
    /// bits [0..31]. Extends txKey with the op dimension.
    function opKey(BlockNumber blockNumber, uint32 txSeq, uint32 opSeq) internal pure returns (OpKey) {
        return OpKey.wrap((TxKey.unwrap(txKey(blockNumber, txSeq)) << 32) | opSeq);
    }
}
