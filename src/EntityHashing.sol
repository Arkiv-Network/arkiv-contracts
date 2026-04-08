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
    /// @return The keccak256 EIP-712 struct hash.
    function attributeHash(Attribute calldata attr) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTRIBUTE_TYPEHASH, attr.name, attr.valueType, attr.fixedValue, keccak256(bytes(attr.stringValue))
            )
        );
    }

    /// @notice Compute the EIP-712 struct hash of an entity's immutable core
    /// content (everything except owner, updatedAt, expiresAt).
    /// @param key       Unique entity key (derived from entityKey()).
    /// @param creator   Address that created the entity.
    /// @param createdAt Block number of entity creation.
    /// @param contentType  MIME-like content type descriptor.
    /// @param payload   Opaque application-specific payload bytes.
    /// @param attributes Sorted attribute array.
    /// @return The keccak256 EIP-712 struct hash.
    function coreHash(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        string calldata contentType,
        bytes calldata payload,
        Attribute[] calldata attributes
    ) internal pure returns (bytes32) {
        bytes32[] memory attrHashes = new bytes32[](attributes.length);
        for (uint256 i = 0; i < attributes.length; i++) {
            attrHashes[i] = attributeHash(attributes[i]);
        }
        return keccak256(
            abi.encode(
                CORE_HASH_TYPEHASH,
                key,
                creator,
                createdAt,
                keccak256(bytes(contentType)),
                keccak256(payload),
                keccak256(abi.encodePacked(attrHashes))
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
    /// @param chainId   The chain ID (typically block.chainid).
    /// @param registry  The registry contract address.
    /// @param owner     The entity owner.
    /// @param nonce     The owner's entity creation nonce.
    /// @return The keccak256 entity key.
    function entityKey(uint256 chainId, address registry, address owner, uint32 nonce) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(chainId, registry, owner, nonce));
    }

    /// @notice Compute the next changeset hash by chaining an operation onto
    /// the previous hash. The changeset is an append-only hash chain where
    /// each link encodes the operation type, entity key, and resulting
    /// entity hash.
    /// @param prev        The changeset hash before this operation.
    /// @param opType      The operation type being recorded.
    /// @param key         The entity key affected.
    /// @param entityHash_ The entity hash after the operation.
    /// @return The new changeset hash.
    function chainOp(bytes32 prev, uint8 opType, bytes32 key, bytes32 entityHash_) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, opType, key, entityHash_));
    }
}
