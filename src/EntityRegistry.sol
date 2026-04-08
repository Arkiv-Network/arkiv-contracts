// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
        TRANSFER,
        DELETE,
        EXPIRE
    }

    struct Op {
        OpType opType;
        bytes32 entityKey; // UPDATE, EXTEND, TRANSFER, DELETE, EXPIRE (ignored for CREATE)
        bytes payload; // CREATE, UPDATE
        string contentType; // CREATE, UPDATE
        Attribute[] attributes; // CREATE, UPDATE
        uint32 expiresAt; // CREATE, EXTEND
        address newOwner; // TRANSFER
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
        uint32 createdAt;
        uint32 updatedAt;
        uint32 expiresAt;
        bytes payload;
        string contentType;
        // Attributes sorted ascending by name for deterministic hash computation.
        Attribute[] attributes;
    }

    // Block-level linked list node for traversing mutation history.
    // All fields pack into a single slot (20 bytes).
    struct BlockNode {
        uint64 prevBlock;
        uint64 nextBlock;
        uint32 txCount;
    }

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error EmptyBatch();

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

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

    mapping(address owner => uint32) public nonces;

    // Three-level changeset hash lookup table.
    //
    // Composite key: (blockNumber << 64) | (txSeq << 32) | opSeq
    //   (block, tx, op) → changeset hash after that specific op
    //
    // No redundant tx-level or block-level snapshots are stored.
    // Those are derived via counts:
    //   tx hash   = _hashAt[(block << 64) | (tx << 32) | _txOpCount[(block << 32) | tx]]
    //   block hash = tx hash of last tx in block (via BlockNode.txCount)
    //
    // Traversal: for block M, walk txSeq 1..blocks[M].txCount,
    //   for each tx walk opSeq 1.._txOpCount[(M << 32) | txSeq].
    //   Across blocks, follow blocks[M].nextBlock.
    mapping(uint256 => bytes32) internal _hashAt;

    // (blockNumber << 32) | txSeq → op count for that tx
    mapping(uint256 => uint32) internal _txOpCount;

    // Block-level linked list: only blocks with mutations have entries.
    // Enables O(1) traversal across sparse blocks.
    mapping(uint256 => BlockNode) internal _blocks;

    // Packed into a single slot (24 bytes):
    //   _headBlock:    first block with mutations (head of linked list)
    //   _tailBlock:    most recent block with mutations (tail of linked list)
    //   _currentTxSeq: tx counter within the current block
    //   _currentOpSeq: op counter within the current tx
    uint64 internal _headBlock;
    uint64 internal _tailBlock;
    uint32 internal _currentTxSeq;
    uint32 internal _currentOpSeq;

    // -------------------------------------------------------------------------
    // Public view functions
    // -------------------------------------------------------------------------

    function changeSetHash() public view returns (bytes32) {
        return _hashAt[(uint256(_tailBlock) << 64) | (uint256(_currentTxSeq) << 32) | _currentOpSeq];
    }

    function entityKey(address owner, uint32 nonce) public view returns (bytes32) {
        return keccak256(abi.encodePacked(block.chainid, address(this), owner, nonce));
    }

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    function execute(Op[] calldata ops) external {
        if (ops.length == 0) revert EmptyBatch();

        // Read previous hash before any counter mutations.
        bytes32 hash = _hashAt[(uint256(_tailBlock) << 64) | (uint256(_currentTxSeq) << 32) | _currentOpSeq];

        // Block transition: maintain the block-level linked list.
        //
        // _headBlock and _tailBlock track the first and most recent mutation
        // blocks respectively. Both are packed into the same slot as the
        // tx/op counters, so updating them costs no additional SSTORE.
        //
        // When we enter a new block:
        //   1. If this is the first mutation ever, set _headBlock.
        //      Otherwise, link the previous tail forward to this block.
        //   2. This block's prevBlock points back to the previous tail.
        //   3. _tailBlock advances to become the new tail.
        //   4. _currentTxSeq resets — tx numbering restarts per block.
        //
        // prevBlock == 0 on the head node means "start of chain."
        // nextBlock == 0 on the tail node means "end of chain."
        if (uint64(block.number) != _tailBlock) {
            uint64 prevBlock = _tailBlock;
            if (prevBlock != 0) {
                _blocks[prevBlock].nextBlock = uint64(block.number);
            } else {
                _headBlock = uint64(block.number);
            }
            _blocks[block.number].prevBlock = prevBlock;
            _tailBlock = uint64(block.number);
            _currentTxSeq = 0;
        }

        // Advance tx sequence within this block.
        // txCount is overwritten each tx so it always reflects the current count.
        _currentTxSeq++;
        uint32 txSeq = _currentTxSeq;
        _blocks[block.number].txCount = txSeq;

        uint256 txKey = (block.number << 64) | (uint256(txSeq) << 32);

        // Process ops — one SSTORE per op for the snapshot.
        uint32 opSeq = 0;
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
            } else if (opType == OpType.TRANSFER) {
                (key, entityHash_) = _transfer(ops[i]);
            } else if (opType == OpType.DELETE) {
                (key, entityHash_) = _delete(ops[i]);
            } else if (opType == OpType.EXPIRE) {
                (key, entityHash_) = _expire(ops[i].entityKey);
            }

            hash = keccak256(abi.encodePacked(hash, opType, key, entityHash_));
            opSeq++;
            _hashAt[txKey | opSeq] = hash;
        }

        // Record op count for this tx and update packed cursor.
        _txOpCount[(block.number << 32) | txSeq] = opSeq;
        _currentOpSeq = opSeq;
    }

    // -------------------------------------------------------------------------
    // Public view functions — changeset hash lookups
    // -------------------------------------------------------------------------

    function changeSetHashAtBlock(uint256 blockNumber) public view returns (bytes32) {
        uint32 txCount = _blocks[blockNumber].txCount;
        if (txCount == 0) return bytes32(0);
        uint32 ops = _txOpCount[(blockNumber << 32) | txCount];
        return _hashAt[(blockNumber << 64) | (uint256(txCount) << 32) | ops];
    }

    function changeSetHashAtTx(uint256 blockNumber, uint32 txSeq) public view returns (bytes32) {
        uint32 ops = _txOpCount[(blockNumber << 32) | txSeq];
        return _hashAt[(blockNumber << 64) | (uint256(txSeq) << 32) | ops];
    }

    function changeSetHashAtOp(uint256 blockNumber, uint32 txSeq, uint32 opSeq) public view returns (bytes32) {
        return _hashAt[(blockNumber << 64) | (uint256(txSeq) << 32) | opSeq];
    }

    function headBlock() public view returns (uint64) {
        return _headBlock;
    }

    function tailBlock() public view returns (uint64) {
        return _tailBlock;
    }

    function getBlockNode(uint256 blockNumber) public view returns (BlockNode memory) {
        return _blocks[blockNumber];
    }

    function txOpCount(uint256 blockNumber, uint32 txSeq) public view returns (uint32) {
        return _txOpCount[(blockNumber << 32) | txSeq];
    }

    // -------------------------------------------------------------------------
    // Internal functions — validation and hashing
    // -------------------------------------------------------------------------

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
        // Validates: content type allowlist, payload size, attribute constraints (sorted, no empty names, unused fields zeroed)
        // Then: mint key via nonce, compute coreHash + entityHash, store entity, expiresAt must be in future
        revert("not implemented");
    }

    function _update(Op calldata op) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner, content type, payload, attributes (same as create)
        // Then: recompute coreHash from new content, update entity, recompute entityHash
        revert("not implemented");
    }

    function _extend(Op calldata op) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner, new expiresAt > current expiresAt
        // Then: update expiresAt + updatedAt, recompute entityHash from stored coreHash
        revert("not implemented");
    }

    function _transfer(Op calldata op) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner, newOwner != address(0)
        // Then: set owner to newOwner + updatedAt, recompute entityHash from stored coreHash
        revert("not implemented");
    }

    function _delete(Op calldata op) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner
        // Then: snapshot entityHash before deletion, delete entity
        revert("not implemented");
    }

    function _expire(bytes32 key) internal returns (bytes32, bytes32) {
        // Validates: entity exists + currentBlock >= expiresAt (entity has expired)
        // Then: snapshot entityHash before deletion, delete entity (callable by anyone)
        revert("not implemented");
    }
}
