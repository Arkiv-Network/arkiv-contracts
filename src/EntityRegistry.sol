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

    function attributeHash(Attribute calldata attr) public pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTRIBUTE_TYPEHASH, attr.name, attr.valueType, attr.fixedValue, keccak256(bytes(attr.stringValue))
            )
        );
    }

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

    function entityKey(address owner, uint32 nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.chainid, address(this), owner, nonce));
    }

    // view (not pure) because _hashTypedDataV4 reads block.chainid to recompute
    // the domain separator if the chain has forked since deployment.
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
