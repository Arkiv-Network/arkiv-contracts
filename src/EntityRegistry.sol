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

    enum OpType {
        CREATE,
        UPDATE,
        EXTEND,
        DELETE,
        EXPIRE
    }

    struct Op {
        OpType opType;
        bytes32 entityKey; // UPDATE, EXTEND, DELETE, EXPIRE (ignored for CREATE)
        bytes payload; // CREATE, UPDATE
        string contentType; // CREATE, UPDATE
        Attribute[] attributes; // CREATE, UPDATE
        BlockNumber expiresAt; // CREATE, EXTEND
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

    // Three-level changeset hash lookup table.
    // Composite key: (blockNumber << 64) | (txSeq << 32) | opSeq
    //   opSeq = 0, txSeq = 0  → block-level snapshot
    //   opSeq = 0, txSeq = N  → tx-level snapshot (after all ops in tx N)
    //   opSeq = M, txSeq = N  → op-level snapshot (after op M in tx N)
    mapping(uint256 => bytes32) internal _hashAt;

    mapping(uint256 blockNumber => uint32) internal _blockTxCount;
    mapping(uint256 blockNumber => uint32) internal _blockOpCount;

    uint64 internal _currentBlock;
    uint32 internal _currentTxSeq;
    uint32 internal _currentOpSeq;

    // -------------------------------------------------------------------------
    // Public view functions
    // -------------------------------------------------------------------------

    function changeSetHash() public view returns (bytes32) {
        return _changeSetHash;
    }

    function entityKey(address owner, uint32 nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.chainid, address(this), owner, nonce));
    }

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    function execute(Op[] calldata ops) external {
        if (uint64(block.number) != _currentBlock) {
            _currentBlock = uint64(block.number);
            _currentTxSeq = 0;
            _currentOpSeq = 0;
        }
        _currentTxSeq++;
        _currentOpSeq = 0;
        _blockTxCount[block.number] = _currentTxSeq;

        bytes32 hash = _changeSetHash;
        uint256 b = block.number << 64;
        uint256 txKey = b | (uint256(_currentTxSeq) << 32);

        for (uint256 i = 0; i < ops.length; i++) {
            OpType opType = ops[i].opType;
            bytes32 key;
            bytes32 entityHash_;

            if (opType == OpType.CREATE) {
                (key, entityHash_) = _create(ops[i]);
            } else if (opType == OpType.UPDATE) {
                (key, entityHash_) = _update(ops[i]);
            } else if (opType == OpType.EXTEND) {
                (key, entityHash_) = _extend(ops[i]);
            } else if (opType == OpType.DELETE) {
                (key, entityHash_) = _delete(ops[i]);
            } else if (opType == OpType.EXPIRE) {
                (key, entityHash_) = _expire(ops[i].entityKey);
            }

            hash = keccak256(abi.encodePacked(hash, opType, key, entityHash_));

            // per-op snapshot
            _currentOpSeq++;
            _hashAt[txKey | _currentOpSeq] = hash;
        }

        _blockOpCount[block.number] = _currentOpSeq;

        // per-tx snapshot
        _hashAt[txKey] = hash;
        // per-block snapshot (overwritten each tx, reflects final state)
        _hashAt[b] = hash;

        _changeSetHash = hash;
    }

    // -------------------------------------------------------------------------
    // Public view functions — changeset hash lookups
    // -------------------------------------------------------------------------

    function changeSetHashAtBlock(uint256 blockNumber) public view returns (bytes32) {
        return _hashAt[blockNumber << 64];
    }

    function changeSetHashAtTx(uint256 blockNumber, uint32 txSeq) public view returns (bytes32) {
        return _hashAt[(blockNumber << 64) | (uint256(txSeq) << 32)];
    }

    function changeSetHashAtOp(uint256 blockNumber, uint32 txSeq, uint32 opSeq) public view returns (bytes32) {
        return _hashAt[(blockNumber << 64) | (uint256(txSeq) << 32) | opSeq];
    }

    function blockTxCount(uint256 blockNumber) public view returns (uint32) {
        return _blockTxCount[blockNumber];
    }

    function blockOpCount(uint256 blockNumber) public view returns (uint32) {
        return _blockOpCount[blockNumber];
    }

    // -------------------------------------------------------------------------
    // Internal functions — validation and hashing
    // -------------------------------------------------------------------------

    function _validate(Op calldata op) internal pure {
        // TODO: validate content type, payload size, attribute constraints
        revert("not implemented");
    }

    function _attributeHash(Attribute calldata attr) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ATTRIBUTE_TYPEHASH, attr.name, attr.valueType, attr.fixedValue, keccak256(bytes(attr.stringValue))
            )
        );
    }

    function _coreHash(
        bytes32 key,
        address creator,
        uint32 createdAt,
        string calldata contentType,
        bytes calldata payload,
        Attribute[] calldata attributes
    ) internal pure returns (bytes32) {
        bytes32[] memory attrHashes = new bytes32[](attributes.length);
        for (uint256 i = 0; i < attributes.length; i++) {
            attrHashes[i] = _attributeHash(attributes[i]);
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

    function _entityHash(bytes32 coreHash_, address owner, uint32 updatedAt, uint32 expiresAt)
        internal
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(keccak256(abi.encode(ENTITY_HASH_TYPEHASH, coreHash_, owner, updatedAt, expiresAt)));
    }

    // -------------------------------------------------------------------------
    // Internal functions — entity operations (skeletons)
    // -------------------------------------------------------------------------

    function _create(Op calldata op) internal returns (bytes32 key, bytes32 entityHash_) {
        _validate(op);
        // TODO: mint key via nonce, compute coreHash + entityHash, store entity
        revert("not implemented");
    }

    function _update(Op calldata op) internal returns (bytes32, bytes32) {
        _validate(op);
        // TODO: load entity, validate ownership + not expired, recompute coreHash + entityHash
        revert("not implemented");
    }

    function _extend(Op calldata op) internal returns (bytes32, bytes32) {
        // TODO: load entity, validate ownership + not expired, update expiresAt, recompute entityHash
        revert("not implemented");
    }

    function _delete(Op calldata op) internal returns (bytes32, bytes32) {
        // TODO: load entity, validate ownership + not expired, snapshot entityHash, delete
        revert("not implemented");
    }

    function _expire(bytes32 key) internal returns (bytes32, bytes32) {
        // TODO: load entity, verify expired, snapshot entityHash, delete
        revert("not implemented");
    }
}
