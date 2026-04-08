// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "./BlockNumber.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {EntityHashing} from "./EntityHashing.sol";

/// @title EntityRegistry
/// @dev Stateful entity registry. All encoding and hashing logic is delegated
/// to the EntityHashing library; this contract manages storage, access control,
/// and the changeset hash chain.
contract EntityRegistry is EIP712("Arkiv EntityRegistry", "1") {
    constructor() {
        _genesisBlock = uint64(block.number);
        _headBlock = uint64(block.number);
    }

    // -------------------------------------------------------------------------
    // State variables
    // -------------------------------------------------------------------------

    mapping(address owner => uint32) public nonces;

    // Three-level changeset hash lookup table.
    //
    // Key: EntityHashing.packHashKey(blockNumber, txSeq, opSeq)
    //   (block, tx, op) → changeset hash after that specific op
    //
    // No redundant tx-level or block-level snapshots are stored.
    // Those are derived via counts:
    //   tx hash   = _hashAt[packHashKey(block, tx, _txOpCount[packTxKey(block, tx)])]
    //   block hash = tx hash of last tx in block (via BlockNode.txCount)
    //
    // Traversal: for block M, walk txSeq 1..blocks[M].txCount,
    //   for each tx walk opSeq 1.._txOpCount[packTxKey(M, txSeq)].
    //   Across blocks, follow blocks[M].nextBlock.
    mapping(uint256 blockTxOpIndex => bytes32 changeSetHash) internal _hashAt;

    // Key: EntityHashing.packTxKey(blockNumber, txSeq) → op count for that tx
    mapping(uint256 blockTxKey => uint32 opCount) internal _txOpCount;

    // Block-level linked list: only blocks with mutations have entries.
    // Enables O(1) traversal across sparse blocks.
    mapping(uint256 blockNumber => EntityHashing.BlockNode node) internal _blocks;

    uint64 internal immutable _genesisBlock;

    // Packed into a single slot (16 bytes):
    //   _headBlock:    most recent block with mutations (head of linked list)
    //   _currentTxSeq: tx counter within the current block
    //   _currentOpSeq: op counter within the current tx
    uint64 internal _headBlock;
    uint32 internal _currentTxSeq;
    uint32 internal _currentOpSeq;

    // -------------------------------------------------------------------------
    // Public view functions
    // -------------------------------------------------------------------------

    function changeSetHash() public view returns (bytes32) {
        return _hashAt[EntityHashing.packHashKey(_headBlock, _currentTxSeq, _currentOpSeq)];
    }

    /// @notice Derive the entity key for an owner and nonce, bound to this
    /// chain and registry instance.
    function entityKey(address owner, uint32 nonce) public view returns (bytes32) {
        return EntityHashing.entityKey(block.chainid, address(this), owner, nonce);
    }

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    function execute(EntityHashing.Op[] calldata ops) external {
        if (ops.length == 0) revert EntityHashing.EmptyBatch();

        // Read previous hash before any counter mutations.
        bytes32 hash = _hashAt[EntityHashing.packHashKey(_headBlock, _currentTxSeq, _currentOpSeq)];

        // Block transition: advance the linked list when entering a new block.
        if (uint64(block.number) != _headBlock) {
            _blocks[_headBlock].nextBlock = uint64(block.number);
            _blocks[block.number].prevBlock = _headBlock;
            _headBlock = uint64(block.number);
            _currentTxSeq = 0;
        }

        // Advance tx sequence within this block.
        // txCount is overwritten each tx so it always reflects the current count.
        _currentTxSeq++;
        uint32 txSeq = _currentTxSeq;
        _blocks[block.number].txCount = txSeq;

        uint256 txKey = EntityHashing.packHashKey(block.number, txSeq, 0);

        // Process ops — one SSTORE per op for the snapshot.
        uint32 opSeq = 0;
        for (uint256 i = 0; i < ops.length; i++) {
            uint8 opType = ops[i].opType;
            bytes32 key;
            bytes32 entityHash_;

            if (opType == EntityHashing.CREATE) {
                (key, entityHash_) = _create(ops[i]);
            } else if (opType == EntityHashing.UPDATE) {
                (key, entityHash_) = _update(ops[i]);
            } else if (opType == EntityHashing.EXTEND) {
                (key, entityHash_) = _extend(ops[i]);
            } else if (opType == EntityHashing.TRANSFER) {
                (key, entityHash_) = _transfer(ops[i]);
            } else if (opType == EntityHashing.DELETE) {
                (key, entityHash_) = _delete(ops[i]);
            } else if (opType == EntityHashing.EXPIRE) {
                (key, entityHash_) = _expire(ops[i].entityKey);
            } else {
                // TODO should not reach here
            }

            hash = EntityHashing.chainOp(hash, opType, key, entityHash_);
            opSeq++;
            _hashAt[txKey | opSeq] = hash;
        }

        // Record op count for this tx and update packed cursor.
        _txOpCount[EntityHashing.packTxKey(block.number, txSeq)] = opSeq;
        _currentOpSeq = opSeq;
    }

    // -------------------------------------------------------------------------
    // Public view functions — changeset hash lookups
    // -------------------------------------------------------------------------

    function changeSetHashAtBlock(uint256 blockNumber) public view returns (bytes32) {
        uint32 txCount = _blocks[blockNumber].txCount;
        if (txCount == 0) return bytes32(0);
        uint32 ops = _txOpCount[EntityHashing.packTxKey(blockNumber, txCount)];
        return _hashAt[EntityHashing.packHashKey(blockNumber, txCount, ops)];
    }

    function changeSetHashAtTx(uint256 blockNumber, uint32 txSeq) public view returns (bytes32) {
        uint32 ops = _txOpCount[EntityHashing.packTxKey(blockNumber, txSeq)];
        return _hashAt[EntityHashing.packHashKey(blockNumber, txSeq, ops)];
    }

    function changeSetHashAtOp(uint256 blockNumber, uint32 txSeq, uint32 opSeq) public view returns (bytes32) {
        return _hashAt[EntityHashing.packHashKey(blockNumber, txSeq, opSeq)];
    }

    function genesisBlock() public view returns (uint64) {
        return _genesisBlock;
    }

    function headBlock() public view returns (uint64) {
        return _headBlock;
    }

    function getBlockNode(uint256 blockNumber) public view returns (EntityHashing.BlockNode memory) {
        return _blocks[blockNumber];
    }

    function txOpCount(uint256 blockNumber, uint32 txSeq) public view returns (uint32) {
        return _txOpCount[EntityHashing.packTxKey(blockNumber, txSeq)];
    }

    // -------------------------------------------------------------------------
    // Internal functions — entity hash (requires domain separator)
    // -------------------------------------------------------------------------

    /// @dev Wraps EntityHashing.entityStructHash with the EIP-712 domain
    /// separator. This is the only hash function that cannot live in the
    /// library because it reads contract storage via _hashTypedDataV4.
    function _entityHash(bytes32 coreHash_, address owner, BlockNumber updatedAt, BlockNumber expiresAt)
        internal
        view
        returns (bytes32)
    {
        return _hashTypedDataV4(EntityHashing.entityStructHash(coreHash_, owner, updatedAt, expiresAt));
    }

    // -------------------------------------------------------------------------
    // Internal functions — entity operations (skeletons)
    // -------------------------------------------------------------------------

    function _create(EntityHashing.Op calldata op) internal returns (bytes32 key, bytes32 entityHash_) {
        // Validates: content type allowlist, payload size, attribute constraints (sorted, no empty names, unused fields zeroed)
        // Then: mint key via nonce, compute coreHash + entityHash, store entity, expiresAt must be in future
        revert("not implemented");
    }

    function _update(EntityHashing.Op calldata op) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner, content type, payload, attributes (same as create)
        // Then: recompute coreHash from new content, update entity, recompute entityHash
        revert("not implemented");
    }

    function _extend(EntityHashing.Op calldata op) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner, new expiresAt > current expiresAt
        // Then: update expiresAt + updatedAt, recompute entityHash from stored coreHash
        revert("not implemented");
    }

    function _transfer(EntityHashing.Op calldata op) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner, newOwner != address(0)
        // Then: set owner to newOwner + updatedAt, recompute entityHash from stored coreHash
        revert("not implemented");
    }

    function _delete(EntityHashing.Op calldata op) internal returns (bytes32, bytes32) {
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
