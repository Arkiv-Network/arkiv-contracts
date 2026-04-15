// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "./BlockNumber.sol";
import {Ident32, validateIdent32} from "./types/Ident32.sol";
import {Mime128} from "./types/Mime128.sol";

type OpKey is uint256;
type TxKey is uint256;

/// @title Entity
/// @dev Pure encoding and hashing scheme for the Arkiv EntityRegistry.
///
/// Separated from the stateful EntityRegistry contract so that the encoding
/// scheme can be reviewed, tested, and reused independently. All functions
/// are `internal` and get inlined by the compiler — zero DELEGATECALL overhead.
///
/// The hashing follows EIP-712 structured data conventions: each struct type
/// has a typehash derived from its canonical type string, and dynamic fields
/// (bytes, string, arrays) are keccak256-hashed before encoding.
library Entity {
    // -------------------------------------------------------------------------
    // Type declarations
    // -------------------------------------------------------------------------

    /// @dev Sentinel value for uninitialized or invalid opType / valueType.
    /// Solidity zero-initializes uint8 fields, so any Op or Attribute with
    /// an unset discriminator will carry this value and be rejected.
    uint8 public constant UNINITIALIZED = 0;

    uint8 public constant CREATE = 1;
    uint8 public constant UPDATE = 2;
    uint8 public constant EXTEND = 3;
    uint8 public constant TRANSFER = 4;
    uint8 public constant DELETE = 5;
    uint8 public constant EXPIRE = 6;

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
        Mime128 contentType;
        Attribute[] attributes;
        BlockNumber expiresAt;
        address newOwner;
    }

    /// @dev Discriminator for attribute value types. Encoded into the
    /// attribute hash so that different types with identical raw bytes
    /// produce distinct hashes.
    uint8 public constant ATTR_UINT = 1;
    uint8 public constant ATTR_STRING = 2;
    uint8 public constant ATTR_ENTITY_KEY = 3;

    /// @dev A typed key-value pair attached to an entity. The `name` is a
    /// validated Ident32 identifier. The `value` is a fixed 128-byte container
    /// (bytes32[4]) — encoding is determined by `valueType` and enforced off-chain.
    /// Attributes must be sorted ascending by name for deterministic hash
    /// computation and name-uniqueness enforcement.
    struct Attribute {
        Ident32 name;
        uint8 valueType;
        bytes32[4] value;
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
    /// @dev Reverted when attributes are not in strictly ascending name order.
    error AttributesNotSorted();
    /// @dev Reverted when an attribute's valueType is unrecognized (including 0 / uninitialized).
    error InvalidValueType(Ident32 name, uint8 valueType);
    /// @dev Reverted when opType is unrecognized (including 0 / uninitialized).
    error InvalidOpType(uint8 opType);
    /// @dev Reverted when expiresAt is not strictly after the current block.
    error ExpiryInPast(BlockNumber expiresAt, BlockNumber currentBlock);
    /// @dev Reverted when the attribute count exceeds MAX_ATTRIBUTES.
    error TooManyAttributes(uint256 count, uint256 maxCount);
    /// @dev Reverted when an entity key does not exist in storage.
    error EntityNotFound(bytes32 entityKey);
    /// @dev Reverted when the caller is not the entity owner.
    error NotOwner(bytes32 entityKey, address caller, address owner);
    /// @dev Reverted when an operation targets an expired entity.
    error EntityExpired(bytes32 entityKey, BlockNumber expiresAt);
    /// @dev Reverted when new expiresAt is not strictly greater than current.
    error ExpiryNotExtended(bytes32 entityKey, BlockNumber newExpiresAt, BlockNumber currentExpiresAt);
    /// @dev Reverted when transfer target is the zero address.
    error TransferToZeroAddress(bytes32 entityKey);
    /// @dev Reverted when transfer target is the current owner (no-op).
    error TransferToSelf(bytes32 entityKey);
    /// @dev Reverted when expire is called on an entity that hasn't expired yet.
    error EntityNotExpired(bytes32 entityKey, BlockNumber expiresAt);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 internal constant MAX_ATTRIBUTES = 32;

    // -------------------------------------------------------------------------
    // Constants — EIP-712 typehashes
    // -------------------------------------------------------------------------

    /// @dev keccak256("Attribute(bytes32 name,uint8 valueType,bytes32[4] value)")
    bytes32 internal constant ATTRIBUTE_TYPEHASH =
        keccak256("Attribute(bytes32 name,uint8 valueType,bytes32[4] value)");

    /// @dev keccak256("CoreHash(bytes32 entityKey,address creator,uint32 createdAt,bytes32[4] contentType,bytes payload,bytes32 attributesHash)")
    bytes32 internal constant CORE_HASH_TYPEHASH = keccak256(
        "CoreHash(bytes32 entityKey,address creator,uint32 createdAt,bytes32[4] contentType,bytes payload,bytes32 attributesHash)"
    );

    /// @dev keccak256("EntityHash(bytes32 coreHash,address owner,uint32 updatedAt,uint32 expiresAt)")
    bytes32 internal constant ENTITY_HASH_TYPEHASH =
        keccak256("EntityHash(bytes32 coreHash,address owner,uint32 updatedAt,uint32 expiresAt)");

    // -------------------------------------------------------------------------
    // Guards
    // -------------------------------------------------------------------------

    /// @dev Require that the entity exists (creator != address(0)).
    function requireExists(bytes32 key, Commitment storage c) internal view {
        if (c.creator == address(0)) revert EntityNotFound(key);
    }

    /// @dev Require that the entity has not expired (expiresAt > current).
    function requireActive(bytes32 key, Commitment storage c, BlockNumber current) internal view {
        if (c.expiresAt <= current) revert EntityExpired(key, c.expiresAt);
    }

    /// @dev Require that the entity has expired (expiresAt <= current).
    function requireExpired(bytes32 key, Commitment storage c, BlockNumber current) internal view {
        if (c.expiresAt > current) revert EntityNotExpired(key, c.expiresAt);
    }

    /// @dev Require that the caller is the entity owner.
    function requireOwner(bytes32 key, Commitment storage c) internal view {
        if (msg.sender != c.owner) revert NotOwner(key, msg.sender, c.owner);
    }

    /// @dev Require that the address is not zero.
    function requireNonZeroAddress(bytes32 key, address addr) internal pure {
        if (addr == address(0)) revert TransferToZeroAddress(key);
    }

    /// @dev Require that the new owner is different from the current owner.
    function requireNewOwner(bytes32 key, address newOwner, address currentOwner) internal pure {
        if (newOwner == currentOwner) revert TransferToSelf(key);
    }

    /// @dev Require that the new expiry is strictly greater than the current one.
    function requireExpiryIncreased(bytes32 key, BlockNumber newExpiresAt, BlockNumber currentExpiresAt) internal pure {
        if (newExpiresAt <= currentExpiresAt) revert ExpiryNotExtended(key, newExpiresAt, currentExpiresAt);
    }

    /// @dev Require that the expiry is strictly in the future.
    function requireFutureExpiry(BlockNumber expiresAt, BlockNumber current) internal pure {
        if (expiresAt <= current) revert ExpiryInPast(expiresAt, current);
    }

    // -------------------------------------------------------------------------
    // Hash functions
    // -------------------------------------------------------------------------

    /// @notice Hash a single attribute and chain it onto the rolling hash.
    /// Validates that this attribute's name is strictly greater than the
    /// previous (lexicographic on the packed bytes32), enforcing sorted
    /// order and name uniqueness.
    /// @return The updated rolling hash.
    function attributeHash(Ident32 prevName, bytes32 chain, Attribute calldata attr)
        internal
        pure
        returns (Ident32, bytes32)
    {
        validateIdent32(attr.name);
        if (attr.name <= prevName) revert AttributesNotSorted();

        if (attr.valueType < ATTR_UINT || attr.valueType > ATTR_ENTITY_KEY) {
            revert InvalidValueType(attr.name, attr.valueType);
        }

        bytes32 valueHash = keccak256(abi.encode(attr.value[0], attr.value[1], attr.value[2], attr.value[3]));
        bytes32 attrHash =
            keccak256(abi.encode(ATTRIBUTE_TYPEHASH, Ident32.unwrap(attr.name), attr.valueType, valueHash));
        return (attr.name, keccak256(abi.encodePacked(chain, attrHash)));
    }

    /// @notice Compute the EIP-712 struct hash of an entity's immutable core
    /// content (everything except owner, updatedAt, expiresAt).
    /// Validates and rolling-hashes the attribute array inline.
    function coreHash(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        Mime128 calldata contentType,
        bytes calldata payload,
        Attribute[] calldata attributes
    ) internal pure returns (bytes32) {
        if (attributes.length > MAX_ATTRIBUTES) {
            revert TooManyAttributes(attributes.length, MAX_ATTRIBUTES);
        }
        bytes32 attrChain;
        Ident32 prevName;
        for (uint256 i = 0; i < attributes.length; i++) {
            (prevName, attrChain) = attributeHash(prevName, attrChain, attributes[i]);
        }
        return keccak256(
            abi.encode(
                CORE_HASH_TYPEHASH,
                key,
                creator,
                createdAt,
                keccak256(
                    abi.encode(contentType.data[0], contentType.data[1], contentType.data[2], contentType.data[3])
                ),
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
    function chainOperationHash(bytes32 prev, uint8 opType, bytes32 key, bytes32 entityHash_) internal pure returns (bytes32) {
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
