// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "./BlockNumber.sol";
import {ShortString, ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract EntityRegistry is EIP712("Arkiv EntityRegistry", "1") {
    using ShortStrings for *;

    // -------------------------------------------------------------------------
    // Type declarations
    // -------------------------------------------------------------------------

    enum OpType {
        CREATE,
        UPDATE,
        EXTEND,
        DELETE,
        EXPIRE
    }

    enum AttributeType {
        UINT,
        STRING,
        ENTITY_KEY
    }

    struct Attribute {
        ShortString name; // up to 31 UTF-8 bytes, packed into bytes32
        AttributeType valueType;
        bytes32 fixedValue; // used for UINT (uint256) and ENTITY_KEY (bytes32)
        string stringValue; // used for STRING
    }

    struct Entity {
        address creator; // slot 0: 20 bytes
        BlockNumber createdAt; // slot 0: +4 bytes
        BlockNumber updatedAt; // slot 0: +4 bytes
        BlockNumber expiresAt; // slot 0: +4 bytes  (= 32 bytes, slot full)
        address owner; // slot 1: 20 bytes
        bytes32 coreHash; // slot 2: 32 bytes
    }

    struct Op {
        OpType opType;
        bytes32 entityKey; // UPDATE, EXTEND, DELETE, EXPIRE (ignored for CREATE)
        bytes payload; // CREATE, UPDATE
        string contentType; // CREATE, UPDATE
        Attribute[] attributes; // CREATE, UPDATE
        BlockNumber expiresAt; // CREATE, EXTEND
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error PayloadTooLarge(uint256 size, uint256 max);
    error TooManyAttributes(uint256 count, uint256 max);
    error StringAttributeTooLarge(ShortString name, uint256 size, uint256 max);
    error AttributesNotSorted(ShortString name, ShortString previousName);
    error EmptyAttributeName(uint256 index);
    error UnusedFieldNotZero(uint256 index);
    error InvalidContentType(string contentType);
    error EntityNotFound(bytes32 entityKey);
    error EntityExpiredError(bytes32 entityKey, BlockNumber expiresAt);
    error NotOwner(bytes32 entityKey, address caller, address owner);
    error ExpiryInPast(BlockNumber expiresAt, BlockNumber currentBlock);
    error ExpiryNotExtended(BlockNumber newExpiresAt, BlockNumber currentExpiresAt);
    error EntityNotExpired(bytes32 entityKey, BlockNumber expiresAt);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event EntityCreated(bytes32 indexed entityKey, address indexed owner, bytes32 entityHash, BlockNumber expiresAt);

    event EntityUpdated(bytes32 indexed entityKey, address indexed owner, bytes32 entityHash);

    event EntityExtended(
        bytes32 indexed entityKey,
        address indexed owner,
        bytes32 entityHash,
        BlockNumber previousExpiresAt,
        BlockNumber newExpiresAt
    );

    event EntityDeleted(bytes32 indexed entityKey, address indexed owner, bytes32 entityHash);

    event EntityExpired(bytes32 indexed entityKey, address indexed owner, bytes32 entityHash, BlockNumber expiresAt);

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant MAX_PAYLOAD_SIZE = 122880; // 120 KB
    uint256 public constant MAX_ATTRIBUTES = 32;
    uint256 public constant MAX_STRING_ATTR_SIZE = 1024; // 1 KB

    bytes32 public constant ATTRIBUTE_TYPEHASH =
        keccak256("Attribute(bytes32 name,uint8 valueType,bytes32 fixedValue,string stringValue)");

    bytes32 public constant CORE_HASH_TYPEHASH = keccak256(
        "CoreHash(bytes32 entityKey,address creator,uint32 createdAt,string contentType,bytes payload,Attribute[] attributes)"
        "Attribute(bytes32 name,uint8 valueType,bytes32 fixedValue,string stringValue)"
    );

    bytes32 public constant ENTITY_HASH_TYPEHASH =
        keccak256("EntityHash(bytes32 coreHash,address owner,uint32 updatedAt,uint32 expiresAt)");

    // -------------------------------------------------------------------------
    // State variables
    // -------------------------------------------------------------------------

    // Per-owner nonce for deterministic, predictable entity key derivation.
    // A global nonce would require waiting for tx inclusion to know the entity key,
    // since concurrent submissions from different owners would contend on the same value.
    // A per-owner nonce is only affected by the owner's own activity, so the next key
    // is predictable client-side before submission.
    mapping(address owner => uint32) public nonces;

    // Running hash over the full ordered sequence of entity mutations.
    // Each mutation chains onto the previous value:
    //   _changeSetHash = keccak256(_changeSetHash || opType || entityKey || entityHash)
    //
    // Transitively commits to every field of every entity through the EIP-712 hash tree:
    //
    //   changeSetHash
    //   ├─ previous changeSetHash       ← full history of all prior mutations
    //   ├─ opType                        ← mutation type (CREATE, UPDATE, EXTEND, DELETE, EXPIRE)
    //   ├─ entityKey                     ← identity of the entity
    //   └─ entityHash                    ← EIP-712 hash of the entity's full state
    //        ├─ coreHash                 ← EIP-712 hash of immutable content
    //        │    ├─ entityKey
    //        │    ├─ creator
    //        │    ├─ createdAt
    //        │    ├─ contentType
    //        │    ├─ keccak256(payload)
    //        │    └─ keccak256(attributeHashes[])
    //        │         └─ per attribute: name, valueType, fixedValue, keccak256(stringValue)
    //        ├─ owner
    //        ├─ updatedAt
    //        └─ expiresAt
    //
    // A single eth_call comparing this value verifies the off-chain DB has processed
    // every mutation in the correct order with the correct content.
    bytes32 internal _changeSetHash;

    mapping(bytes32 => Entity) public entities;

    // Content type allowlist — keyed by keccak256 of the content type string.
    // Seeded in the constructor. O(1) lookup via single SLOAD.
    mapping(bytes32 => bool) public validContentTypes;

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor() {
        validContentTypes[keccak256("application/json")] = true;
        validContentTypes[keccak256("application/octet-stream")] = true;
        validContentTypes[keccak256("application/pdf")] = true;
        validContentTypes[keccak256("application/cbor")] = true;
        validContentTypes[keccak256("text/plain")] = true;
        validContentTypes[keccak256("text/csv")] = true;
        validContentTypes[keccak256("text/html")] = true;
    }

    // -------------------------------------------------------------------------
    // Public view functions
    // -------------------------------------------------------------------------

    /// @notice Returns the cumulative change set hash over all entity mutations.
    /// The off-chain DB computes the same chain and compares against this single value.
    function changeSetHash() public view returns (bytes32) {
        return _changeSetHash;
    }

    /// @notice Computes the unique identifier for an entity.
    ///
    /// The entity key is deterministic and predictable before transaction submission.
    /// A client reads the owner's current nonce and computes the key locally — no need
    /// to wait for tx inclusion.
    ///
    /// Components:
    ///   - block.chainid:    prevents key collisions across chains
    ///   - address(this):    prevents collisions across EntityRegistry deployments
    ///   - owner:            the address that creates the entity (immutable after creation)
    ///   - nonce:            per-owner counter, incremented on each create
    ///
    /// The per-owner nonce (rather than a global counter) ensures that only the owner's
    /// own activity affects their next key. Concurrent submissions from different owners
    /// do not contend, so the key is always predictable client-side.
    ///
    /// Entity keys are never reused. Once a nonce is consumed, that key is permanently
    /// assigned — even if the entity is later deleted or expires.
    function entityKey(address owner, uint32 nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.chainid, address(this), owner, nonce));
    }

    /// @notice Computes the full EIP-712 entity hash from a core hash and mutable fields.
    ///
    /// The entity hash is a two-part EIP-712 structured hash:
    ///
    ///   entityHash = EIP712_hash(EntityHash(coreHash, owner, updatedAt, expiresAt))
    ///
    /// The two-part structure separates immutable content (in coreHash) from mutable
    /// metadata (owner, updatedAt, expiresAt). This enables operations that only change
    /// mutable fields — extendEntity and changeOwner — to recompute the entity hash
    /// from on-chain state alone, without needing the payload or attributes.
    ///
    /// coreHash commits to: entityKey, creator, createdAt, contentType, payload, attributes.
    /// It is stable across owner changes and expiry extensions.
    ///
    /// The EIP-712 domain separator (name: "Arkiv EntityRegistry", version: "1") binds
    /// the hash to this specific contract deployment and chain, preventing cross-chain
    /// and cross-contract hash collisions.
    ///
    /// This function is view (not pure) because _hashTypedDataV4 reads block.chainid
    /// to recompute the domain separator if the chain has forked since deployment.
    function entityHash(bytes32 _coreHash, address owner, uint32 updatedAt, uint32 expiresAt)
        public
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(ENTITY_HASH_TYPEHASH, _coreHash, owner, updatedAt, expiresAt)));
    }

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    function execute(Op[] calldata ops) external {
        for (uint256 i = 0; i < ops.length; i++) {
            OpType opType = ops[i].opType;
            if (opType == OpType.CREATE) {
                _create(ops[i]);
            } else if (opType == OpType.UPDATE) {
                _update(ops[i]);
            } else if (opType == OpType.EXTEND) {
                _extend(ops[i]);
            } else if (opType == OpType.DELETE) {
                _delete(ops[i]);
            } else if (opType == OpType.EXPIRE) {
                _expire(ops[i].entityKey);
            }
        }
    }

    function expireEntities(bytes32[] calldata keys) external {
        for (uint256 i = 0; i < keys.length; i++) {
            _expire(keys[i]);
        }
    }

    // -------------------------------------------------------------------------
    // Internal functions
    // -------------------------------------------------------------------------

    /// @dev Loads an entity, reverts if not found, not expired check, and owner check.
    /// Used by update, extend, delete — all owner-gated mutations on active entities.
    function _loadActiveOwnedEntity(bytes32 key) internal view returns (Entity storage entity) {
        entity = entities[key];
        if (entity.creator == address(0)) revert EntityNotFound(key);
        if (currentBlock() >= entity.expiresAt) revert EntityExpiredError(key, entity.expiresAt);
        if (msg.sender != entity.owner) revert NotOwner(key, msg.sender, entity.owner);
    }

    /// @dev Computes entityHash from a stored entity's current fields.
    function _entityHashFromStorage(Entity storage entity) internal view returns (bytes32) {
        return entityHash(
            entity.coreHash, entity.owner, BlockNumber.unwrap(entity.updatedAt), BlockNumber.unwrap(entity.expiresAt)
        );
    }

    /// @dev Computes the EIP-712 struct hash for a single attribute.
    ///
    /// Every field is included in the hash regardless of the attribute type:
    ///   - name:        ShortString (up to 31 bytes), encoded as bytes32
    ///   - valueType:   the type discriminator (UINT=0, STRING=1, ENTITY_KEY=2)
    ///   - fixedValue:  used by UINT and ENTITY_KEY; zero for STRING
    ///   - stringValue: used by STRING; empty for UINT and ENTITY_KEY, hashed via keccak256
    ///
    /// All four fields contribute to the hash even when semantically unused for a given
    /// type. This means callers must zero unused fields — a STRING attribute with a
    /// non-zero fixedValue will produce a different hash than one with fixedValue=0,
    /// even though fixedValue is semantically meaningless for STRING.
    ///
    /// The valueType field prevents type confusion: a UINT attribute and an ENTITY_KEY
    /// attribute with the same name and fixedValue produce different hashes.
    function _attributeHash(Attribute calldata attr) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTRIBUTE_TYPEHASH, attr.name, attr.valueType, attr.fixedValue, keccak256(bytes(attr.stringValue))
            )
        );
    }

    /// @dev Computes the EIP-712 core hash — the immutable content commitment of an entity.
    ///
    /// The core hash captures everything about an entity that does not change after creation
    /// (except on update, which replaces the core hash entirely):
    ///   - key:          the entity's unique identifier
    ///   - creator:      the address that created the entity (immutable, distinct from owner)
    ///   - createdAt:    the block number at creation (immutable)
    ///   - contentType:  the MIME type of the payload (hashed via keccak256)
    ///   - payload:      the entity's content (hashed via keccak256, not stored on-chain)
    ///   - attrHashes:   pre-computed EIP-712 hashes of each attribute, concatenated and hashed
    ///
    /// The core hash is the inner part of the two-part entity hash structure. It is stable
    /// across extendEntity and changeOwner — those operations only modify mutable fields
    /// (owner, updatedAt, expiresAt) in the outer entityHash. This means the contract can
    /// recompute entityHash for those operations using only the stored coreHash and on-chain
    /// metadata, without needing the payload or attributes.
    ///
    /// Attribute ordering matters: the same attributes in a different order produce a
    /// different core hash. The contract requires attributes to be sorted ascending by
    /// name (enforced by _validateAndHash) to ensure deterministic hashing across all
    /// implementations.
    function _coreHash(
        bytes32 key,
        address creator,
        uint32 createdAt,
        string calldata contentType,
        bytes calldata payload,
        bytes32[] memory attrHashes
    ) internal pure returns (bytes32) {
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

    /// @dev Validates content type, payload, and attributes, then computes coreHash
    /// in a single pass over attributes. Used by create and update.
    function _validateAndHash(
        bytes32 key,
        address creator,
        uint32 createdAt,
        string calldata contentType,
        bytes calldata payload,
        Attribute[] calldata attributes
    ) internal view returns (bytes32) {
        if (!validContentTypes[keccak256(bytes(contentType))]) {
            revert InvalidContentType(contentType);
        }
        if (payload.length > MAX_PAYLOAD_SIZE) {
            revert PayloadTooLarge(payload.length, MAX_PAYLOAD_SIZE);
        }
        if (attributes.length > MAX_ATTRIBUTES) {
            revert TooManyAttributes(attributes.length, MAX_ATTRIBUTES);
        }

        bytes32[] memory attrHashes = new bytes32[](attributes.length);
        for (uint256 i = 0; i < attributes.length; i++) {
            if (ShortString.unwrap(attributes[i].name) == bytes32(0)) {
                revert EmptyAttributeName(i);
            }
            if (attributes[i].valueType == AttributeType.STRING) {
                uint256 strSize = bytes(attributes[i].stringValue).length;
                if (strSize > MAX_STRING_ATTR_SIZE) {
                    revert StringAttributeTooLarge(attributes[i].name, strSize, MAX_STRING_ATTR_SIZE);
                }
                if (attributes[i].fixedValue != bytes32(0)) {
                    revert UnusedFieldNotZero(i);
                }
            } else {
                if (bytes(attributes[i].stringValue).length != 0) {
                    revert UnusedFieldNotZero(i);
                }
            }
            if (i > 0 && ShortString.unwrap(attributes[i].name) <= ShortString.unwrap(attributes[i - 1].name)) {
                revert AttributesNotSorted(attributes[i].name, attributes[i - 1].name);
            }
            attrHashes[i] = _attributeHash(attributes[i]);
        }

        return _coreHash(key, creator, createdAt, contentType, payload, attrHashes);
    }

    function _accumulateChangeSet(OpType opType, bytes32 key, bytes32 _entityHash) internal {
        _changeSetHash = keccak256(abi.encodePacked(_changeSetHash, opType, key, _entityHash));
    }

    function _create(Op calldata op) internal {
        if (op.expiresAt <= currentBlock()) {
            revert ExpiryInPast(op.expiresAt, currentBlock());
        }

        uint32 nonce = nonces[msg.sender]++;
        bytes32 key = entityKey(msg.sender, nonce);
        BlockNumber now_ = currentBlock();

        bytes32 _coreHash =
            _validateAndHash(key, msg.sender, BlockNumber.unwrap(now_), op.contentType, op.payload, op.attributes);
        bytes32 _entityHash =
            entityHash(_coreHash, msg.sender, BlockNumber.unwrap(now_), BlockNumber.unwrap(op.expiresAt));

        entities[key] = Entity({
            creator: msg.sender,
            createdAt: now_,
            updatedAt: now_,
            expiresAt: op.expiresAt,
            owner: msg.sender,
            coreHash: _coreHash
        });

        _accumulateChangeSet(OpType.CREATE, key, _entityHash);
        emit EntityCreated(key, msg.sender, _entityHash, op.expiresAt);
    }

    function _update(Op calldata op) internal {
        Entity storage entity = _loadActiveOwnedEntity(op.entityKey);
        BlockNumber now_ = currentBlock();

        bytes32 _coreHash = _validateAndHash(
            op.entityKey,
            entity.creator,
            BlockNumber.unwrap(entity.createdAt),
            op.contentType,
            op.payload,
            op.attributes
        );

        entity.coreHash = _coreHash;
        entity.updatedAt = now_;

        bytes32 _entityHash =
            entityHash(_coreHash, entity.owner, BlockNumber.unwrap(now_), BlockNumber.unwrap(entity.expiresAt));

        _accumulateChangeSet(OpType.UPDATE, op.entityKey, _entityHash);
        emit EntityUpdated(op.entityKey, entity.owner, _entityHash);
    }

    function _extend(Op calldata op) internal {
        Entity storage entity = _loadActiveOwnedEntity(op.entityKey);
        if (op.expiresAt <= entity.expiresAt) {
            revert ExpiryNotExtended(op.expiresAt, entity.expiresAt);
        }

        BlockNumber previousExpiresAt = entity.expiresAt;
        BlockNumber now_ = currentBlock();
        entity.expiresAt = op.expiresAt;
        entity.updatedAt = now_;

        bytes32 _entityHash =
            entityHash(entity.coreHash, entity.owner, BlockNumber.unwrap(now_), BlockNumber.unwrap(op.expiresAt));

        _accumulateChangeSet(OpType.EXTEND, op.entityKey, _entityHash);
        emit EntityExtended(op.entityKey, entity.owner, _entityHash, previousExpiresAt, op.expiresAt);
    }

    function _delete(Op calldata op) internal {
        Entity storage entity = _loadActiveOwnedEntity(op.entityKey);
        bytes32 _entityHash = _entityHashFromStorage(entity);
        address owner = entity.owner;

        delete entities[op.entityKey];

        _accumulateChangeSet(OpType.DELETE, op.entityKey, _entityHash);
        emit EntityDeleted(op.entityKey, owner, _entityHash);
    }

    function _expire(bytes32 key) internal {
        Entity storage entity = entities[key];
        if (entity.creator == address(0)) revert EntityNotFound(key);
        if (currentBlock() < entity.expiresAt) revert EntityNotExpired(key, entity.expiresAt);

        bytes32 _entityHash = _entityHashFromStorage(entity);
        address owner = entity.owner;
        BlockNumber expiresAt = entity.expiresAt;

        delete entities[key];

        _accumulateChangeSet(OpType.EXPIRE, key, _entityHash);
        emit EntityExpired(key, owner, _entityHash, expiresAt);
    }
}
