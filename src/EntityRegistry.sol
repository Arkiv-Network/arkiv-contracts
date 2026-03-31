// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "./BlockNumber.sol";
import {ShortString, ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract EntityRegistry is EIP712("Arkiv EntityRegistry", "1") {
    using ShortStrings for *;

    // -------------------------------------------------------------------------
    // Type declarations
    // -------------------------------------------------------------------------

    enum Op {
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
        address creator;
        address owner;
        BlockNumber createdAt;
        BlockNumber updatedAt;
        BlockNumber expiresAt;
        bytes payload;
        string contentType;
        // Attributes sorted ascending by name for deterministic hash computation.
        Attribute[] attributes;
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error PayloadTooLarge(uint256 size, uint256 max);
    error TooManyAttributes(uint256 count, uint256 max);
    error StringAttributeTooLarge(ShortString name, uint256 size, uint256 max);
    error AttributesNotSorted(ShortString name, ShortString previousName);
    error EmptyAttributeName(uint256 index);

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
    //   _changeSetHash = keccak256(_changeSetHash || op || entityKey || entityHash)
    //
    // Transitively commits to every field of every entity through the EIP-712 hash tree:
    //
    //   changeSetHash
    //   ├─ previous changeSetHash       ← full history of all prior mutations
    //   ├─ op                            ← mutation type (CREATE, UPDATE, EXTEND, DELETE, EXPIRE)
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

    // -------------------------------------------------------------------------
    // Public pure functions
    // -------------------------------------------------------------------------

    function validateEntity(bytes calldata payload, Attribute[] calldata attributes) public pure {
        if (payload.length > MAX_PAYLOAD_SIZE) {
            revert PayloadTooLarge(payload.length, MAX_PAYLOAD_SIZE);
        }
        if (attributes.length > MAX_ATTRIBUTES) {
            revert TooManyAttributes(attributes.length, MAX_ATTRIBUTES);
        }

        for (uint256 i = 0; i < attributes.length; i++) {
            if (ShortString.unwrap(attributes[i].name) == bytes32(0)) {
                revert EmptyAttributeName(i);
            }

            if (attributes[i].valueType == AttributeType.STRING) {
                uint256 strSize = bytes(attributes[i].stringValue).length;
                if (strSize > MAX_STRING_ATTR_SIZE) {
                    revert StringAttributeTooLarge(attributes[i].name, strSize, MAX_STRING_ATTR_SIZE);
                }
            }

            if (i > 0 && ShortString.unwrap(attributes[i].name) <= ShortString.unwrap(attributes[i - 1].name)) {
                revert AttributesNotSorted(attributes[i].name, attributes[i - 1].name);
            }
        }
    }

    /// @notice Computes the EIP-712 struct hash for a single attribute.
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
    function attributeHash(Attribute calldata attr) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTRIBUTE_TYPEHASH, attr.name, attr.valueType, attr.fixedValue, keccak256(bytes(attr.stringValue))
            )
        );
    }

    /// @notice Computes the EIP-712 core hash — the immutable content commitment of an entity.
    ///
    /// The core hash captures everything about an entity that does not change after creation
    /// (except on update, which replaces the core hash entirely):
    ///   - key:          the entity's unique identifier
    ///   - creator:      the address that created the entity (immutable, distinct from owner)
    ///   - createdAt:    the block number at creation (immutable)
    ///   - contentType:  the MIME type of the payload (hashed via keccak256)
    ///   - payload:      the entity's content (hashed via keccak256, not stored on-chain)
    ///   - attributes:   entity metadata for querying (each hashed individually, then
    ///                   the array of hashes is concatenated and hashed)
    ///
    /// The core hash is the inner part of the two-part entity hash structure. It is stable
    /// across extendEntity and changeOwner — those operations only modify mutable fields
    /// (owner, updatedAt, expiresAt) in the outer entityHash. This means the contract can
    /// recompute entityHash for those operations using only the stored coreHash and on-chain
    /// metadata, without needing the payload or attributes.
    ///
    /// Attribute ordering matters: the same attributes in a different order produce a
    /// different core hash. The contract requires attributes to be sorted ascending by
    /// name (enforced by validateEntity) to ensure deterministic hashing across all
    /// implementations.
    function coreHash(
        bytes32 key,
        address creator,
        uint32 createdAt,
        string calldata contentType,
        bytes calldata payload,
        Attribute[] calldata attributes
    ) public pure returns (bytes32) {
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
    // Internal functions
    // -------------------------------------------------------------------------

    function _op(Op op, bytes32 _entityKey, bytes32 _entityHash) internal {
        // TODO: entity mutation logic per op type
        _accumulateChangeSet(op, _entityKey, _entityHash);
    }

    function _accumulateChangeSet(Op op, bytes32 _entityKey, bytes32 _entityHash) internal {
        _changeSetHash = keccak256(abi.encodePacked(_changeSetHash, op, _entityKey, _entityHash));
    }
}
