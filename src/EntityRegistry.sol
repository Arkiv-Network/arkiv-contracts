// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "./BlockNumber.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {EntityHashing, OpKey, TxKey} from "./EntityHashing.sol";

/// @title EntityRegistry
/// @dev Stateful entity registry. All encoding and hashing logic is delegated
/// to the EntityHashing library; this contract manages storage, access control,
/// and the changeset hash chain.
contract EntityRegistry is EIP712("Arkiv EntityRegistry", "1") {
    constructor() {
        _genesisBlock = uint64(block.number);
    }

    // -------------------------------------------------------------------------
    // State variables
    // -------------------------------------------------------------------------

    mapping(address owner => uint32) public nonces;

    // Three-level changeset hash lookup table.
    //
    // Key: EntityHashing.opKey(blockNumber, txSeq, opSeq)
    //   (block, tx, op) → changeset hash after that specific op
    //
    // All indices are 0-based. No redundant tx-level or block-level snapshots
    // are stored — those are derived via counts:
    //   tx hash   = _hashAt[opKey(block, lastTx, lastOp)]
    //   block hash = tx hash of last tx in block (via BlockNode.txCount)
    //
    // Traversal: for block M, walk txSeq 0..blocks[M].txCount-1,
    //   for each tx walk opSeq 0.._txOpCount[txKey(M, txSeq)]-1.
    //   Across blocks, follow blocks[M].nextBlock.
    mapping(OpKey opKey => bytes32 changeSetHash) internal _hashAt;

    // Key: EntityHashing.txKey(blockNumber, txSeq) → op count for that tx
    mapping(TxKey txKey => uint32 opCount) internal _txOpCount;

    // Block-level linked list: only blocks with mutations have entries.
    // Enables O(1) traversal across sparse blocks.
    mapping(uint256 blockNumber => EntityHashing.BlockNode node) internal _blocks;

    uint64 internal immutable _genesisBlock;

    // _headBlock: most recent block with mutations (head of linked list)
    uint64 internal _headBlock;

    // -------------------------------------------------------------------------
    // Public view functions
    // -------------------------------------------------------------------------

    function changeSetHash() public view returns (bytes32) {
        return changeSetHashAtBlock(_headBlock);
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

        // Read previous hash from the head of the chain.
        bytes32 hash = changeSetHash();

        // Block transition: maintain the block-level linked list.
        //
        // When we enter a new block:
        //   1. Link the previous head forward to this block.
        //   2. This block's prevBlock points back to the previous head.
        //   3. _headBlock advances to the current block.
        //
        // prevBlock == 0 on the genesis node means "start of chain."
        // nextBlock == 0 on the head node means "end of chain."
        uint32 txSeq;
        if (uint64(block.number) != _headBlock) {
            uint64 prevHead = _headBlock;
            if (prevHead != 0) {
                _blocks[prevHead].nextBlock = uint64(block.number);
            }
            _blocks[block.number].prevBlock = prevHead;
            _headBlock = uint64(block.number);
            // txSeq = 0 (default)
        } else {
            txSeq = _blocks[block.number].txCount;
        }

        _blocks[block.number].txCount = txSeq + 1;

        // Process ops — one SSTORE per op for the snapshot.
        for (uint32 opSeq = 0; opSeq < ops.length; opSeq++) {
            uint8 opType = ops[opSeq].opType;
            bytes32 key;
            bytes32 entityHash_;

            if (opType == EntityHashing.CREATE) {
                (key, entityHash_) = _create(ops[opSeq]);
            } else if (opType == EntityHashing.UPDATE) {
                (key, entityHash_) = _update(ops[opSeq]);
            } else if (opType == EntityHashing.EXTEND) {
                (key, entityHash_) = _extend(ops[opSeq]);
            } else if (opType == EntityHashing.TRANSFER) {
                (key, entityHash_) = _transfer(ops[opSeq]);
            } else if (opType == EntityHashing.DELETE) {
                (key, entityHash_) = _delete(ops[opSeq]);
            } else if (opType == EntityHashing.EXPIRE) {
                (key, entityHash_) = _expire(ops[opSeq].entityKey);
            } else {
                // TODO should not reach here
            }

            hash = EntityHashing.chainOp(hash, opType, key, entityHash_);
            _hashAt[EntityHashing.opKey(block.number, txSeq, opSeq)] = hash;
        }

        // Record op count for this tx.
        _txOpCount[EntityHashing.txKey(block.number, txSeq)] = uint32(ops.length);
    }

    // -------------------------------------------------------------------------
    // Public view functions — changeset hash lookups
    // -------------------------------------------------------------------------

    function changeSetHashAtBlock(uint256 blockNumber) public view returns (bytes32) {
        uint32 txCount = _blocks[blockNumber].txCount;
        if (txCount == 0) return bytes32(0);
        uint32 lastTx = txCount - 1;
        uint32 opCount = _txOpCount[EntityHashing.txKey(blockNumber, lastTx)];
        return _hashAt[EntityHashing.opKey(blockNumber, lastTx, opCount - 1)];
    }

    function changeSetHashAtTx(uint256 blockNumber, uint32 txSeq) public view returns (bytes32) {
        uint32 opCount = _txOpCount[EntityHashing.txKey(blockNumber, txSeq)];
        return _hashAt[EntityHashing.opKey(blockNumber, txSeq, opCount - 1)];
    }

    function changeSetHashAtOp(uint256 blockNumber, uint32 txSeq, uint32 opSeq) public view returns (bytes32) {
        return _hashAt[EntityHashing.opKey(blockNumber, txSeq, opSeq)];
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
        return _txOpCount[EntityHashing.txKey(blockNumber, txSeq)];
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
