// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "./BlockNumber.sol";
import {ShortString} from "@openzeppelin/contracts/utils/ShortStrings.sol";

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
    enum AttributeType {
        UINT,
        STRING,
        ENTITY_KEY
    }

    /// @dev A typed key-value pair attached to an entity. The `name` field
    /// uses OpenZeppelin's ShortString (up to 31 UTF-8 bytes packed into
    /// bytes32) for gas-efficient storage and comparison. Attributes must
    /// be sorted ascending by name for deterministic hash computation.
    struct Attribute {
        ShortString name;
        AttributeType valueType;
        bytes32 fixedValue; // UINT (uint256) or ENTITY_KEY (bytes32)
        string stringValue; // STRING
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

    // -------------------------------------------------------------------------
    // Constants — EIP-712 typehashes
    // -------------------------------------------------------------------------

    /// @dev keccak256("Attribute(bytes32 name,uint8 valueType,bytes32 fixedValue,string stringValue)")
    bytes32 internal constant ATTRIBUTE_TYPEHASH =
        keccak256("Attribute(bytes32 name,uint8 valueType,bytes32 fixedValue,string stringValue)");

    /// @dev keccak256("CoreHash(bytes32 entityKey,...,Attribute[] attributes)Attribute(...)")
    /// Includes the referenced Attribute type string per EIP-712 § hashStruct.
    bytes32 internal constant CORE_HASH_TYPEHASH = keccak256(
        "CoreHash(bytes32 entityKey,address creator,uint32 createdAt,string contentType,bytes payload,Attribute[] attributes)"
        "Attribute(bytes32 name,uint8 valueType,bytes32 fixedValue,string stringValue)"
    );

    /// @dev keccak256("EntityHash(bytes32 coreHash,address owner,uint32 updatedAt,uint32 expiresAt)")
    bytes32 internal constant ENTITY_HASH_TYPEHASH =
        keccak256("EntityHash(bytes32 coreHash,address owner,uint32 updatedAt,uint32 expiresAt)");

    // -------------------------------------------------------------------------
    // Hash functions
    // -------------------------------------------------------------------------

    /// @notice Compute the EIP-712 struct hash of a single attribute.
    /// @param attr The attribute to hash.
    /// @return result The keccak256 EIP-712 struct hash.
    function attributeHash(Attribute calldata attr) internal pure returns (bytes32 result) {
        bytes32 th = ATTRIBUTE_TYPEHASH;
        bytes32 svHash = keccak256(bytes(attr.stringValue));
        bytes32 name = ShortString.unwrap(attr.name);
        uint8 vt = uint8(attr.valueType);
        bytes32 fv = attr.fixedValue;
        assembly {
            let m := mload(0x40)
            mstore(m, th)
            mstore(add(m, 0x20), name)
            mstore(add(m, 0x40), vt)
            mstore(add(m, 0x60), fv)
            mstore(add(m, 0x80), svHash)
            result := keccak256(m, 0xa0) // 5 × 32 = 160
        }
    }

    /// @notice Compute the EIP-712 struct hash of an entity's immutable core
    /// content (everything except owner, updatedAt, expiresAt).
    /// @param key       Unique entity key (derived from entityKey()).
    /// @param creator   Address that created the entity.
    /// @param createdAt Block number of entity creation.
    /// @param contentType  MIME-like content type descriptor.
    /// @param payload   Opaque application-specific payload bytes.
    /// @param attributes Sorted attribute array.
    /// @return result The keccak256 EIP-712 struct hash.
    function coreHash(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        string calldata contentType,
        bytes calldata payload,
        Attribute[] calldata attributes
    ) internal pure returns (bytes32 result) {
        bytes32 ctHash = keccak256(bytes(contentType));
        bytes32 plHash = keccak256(payload);

        bytes32[] memory attrHashes = new bytes32[](attributes.length);
        for (uint256 i = 0; i < attributes.length; i++) {
            attrHashes[i] = attributeHash(attributes[i]);
        }

        // Hash the attribute array: abi.encodePacked(bytes32[]) is the raw
        // data without the length prefix, so we skip the first 32 bytes.
        bytes32 ahHash;
        assembly {
            ahHash := keccak256(add(attrHashes, 0x20), mul(mload(attrHashes), 0x20))
        }

        bytes32 th = CORE_HASH_TYPEHASH;
        assembly {
            let m := mload(0x40)
            mstore(m, th)
            mstore(add(m, 0x20), key)
            mstore(add(m, 0x40), creator)
            mstore(add(m, 0x60), createdAt)
            mstore(add(m, 0x80), ctHash)
            mstore(add(m, 0xa0), plHash)
            mstore(add(m, 0xc0), ahHash)
            result := keccak256(m, 0xe0) // 7 × 32 = 224
        }
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

    /// @notice Pack a (block, tx, op) triple into a single uint256 key for
    /// the `_hashAt` mapping. Layout: block in bits [64..127], tx in bits
    /// [32..63], op in bits [0..31].
    /// @param blockNumber Block number (uint64 range).
    /// @param txSeq       Transaction sequence within the block.
    /// @param opSeq       Operation sequence within the transaction.
    /// @return The packed mapping key.
    function packHashKey(uint256 blockNumber, uint32 txSeq, uint32 opSeq) internal pure returns (uint256) {
        return (blockNumber << 64) | (uint256(txSeq) << 32) | opSeq;
    }

    /// @notice Pack a (block, tx) pair into a single uint256 key for the
    /// `_txOpCount` mapping. Layout: block in bits [32..95], tx in bits [0..31].
    /// @param blockNumber Block number (uint64 range).
    /// @param txSeq       Transaction sequence within the block.
    /// @return The packed mapping key.
    function packTxKey(uint256 blockNumber, uint32 txSeq) internal pure returns (uint256) {
        return (blockNumber << 32) | txSeq;
    }
}
