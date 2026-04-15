// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "./BlockNumber.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {EntityHashing, OpKey, TxKey} from "./EntityHashing.sol";
import {validateMime128} from "./types/Mime128.sol";

/// @title EntityRegistry
/// @dev Stateful entity registry. All encoding and hashing logic is delegated
/// to the EntityHashing library; this contract manages storage, access control,
/// and the changeset hash chain.
contract EntityRegistry is EIP712("Arkiv EntityRegistry", "1") {
    constructor() {
        BlockNumber genesis = currentBlock();
        _genesisBlock = genesis;
        _headBlock = genesis;
    }

    // -------------------------------------------------------------------------
    // State variables
    // -------------------------------------------------------------------------

    /// @dev Per-owner monotonic counter used to derive unique entity keys.
    mapping(address owner => uint32) internal _nonces;

    /// @dev Entity commitment map: entityKey → Commitment.
    /// Stores only the fields needed to recompute entityHash from chain
    /// state alone. Full entity data (payload, attributes) lives in
    /// calldata/events for the off-chain DB.
    mapping(bytes32 entityKey => EntityHashing.Commitment) internal _commitments;

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
    mapping(BlockNumber blockNumber => EntityHashing.BlockNode node) internal _blocks;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event EntityOp(
        bytes32 indexed entityKey,
        uint8 indexed opType,
        address indexed owner,
        BlockNumber expiresAt,
        bytes32 entityHash
    );

    // -------------------------------------------------------------------------
    // State — block chain pointers
    // -------------------------------------------------------------------------

    BlockNumber internal immutable _genesisBlock;
    BlockNumber internal _headBlock;

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

        bytes32 hash = changeSetHash();

        // Block bookkeeping: advance the linked list on a new block,
        // or continue the current block's tx sequence.
        BlockNumber current = currentBlock();
        uint32 txSeq;
        if (current != _headBlock) {
            _blocks[_headBlock].nextBlock = current;
            _blocks[current].prevBlock = _headBlock;
            _headBlock = current;
        } else {
            txSeq = _blocks[current].txCount;
        }
        _blocks[current].txCount = txSeq + 1;

        // Dispatch each op and extend the changeset hash chain.
        for (uint32 opSeq = 0; opSeq < ops.length; opSeq++) {
            (bytes32 key, bytes32 entityHash_) = _dispatch(ops[opSeq], current);
            hash = EntityHashing.chainOp(hash, ops[opSeq].opType, key, entityHash_);
            _hashAt[EntityHashing.opKey(current, txSeq, opSeq)] = hash;
        }

        _txOpCount[EntityHashing.txKey(current, txSeq)] = uint32(ops.length);
    }

    // -------------------------------------------------------------------------
    // Public view functions — changeset hash lookups
    // -------------------------------------------------------------------------

    function changeSetHashAtBlock(BlockNumber blockNumber) public view returns (bytes32) {
        uint32 txCount = _blocks[blockNumber].txCount;
        if (txCount == 0) return bytes32(0);
        uint32 lastTx = txCount - 1;
        uint32 opCount = _txOpCount[EntityHashing.txKey(blockNumber, lastTx)];
        return _hashAt[EntityHashing.opKey(blockNumber, lastTx, opCount - 1)];
    }

    function changeSetHashAtTx(BlockNumber blockNumber, uint32 txSeq) public view returns (bytes32) {
        uint32 opCount = _txOpCount[EntityHashing.txKey(blockNumber, txSeq)];
        if (opCount == 0) return bytes32(0);
        return _hashAt[EntityHashing.opKey(blockNumber, txSeq, opCount - 1)];
    }

    function changeSetHashAtOp(BlockNumber blockNumber, uint32 txSeq, uint32 opSeq) public view returns (bytes32) {
        return _hashAt[EntityHashing.opKey(blockNumber, txSeq, opSeq)];
    }

    function genesisBlock() public view returns (BlockNumber) {
        return _genesisBlock;
    }

    function headBlock() public view returns (BlockNumber) {
        return _headBlock;
    }

    function getBlockNode(BlockNumber blockNumber) public view returns (EntityHashing.BlockNode memory) {
        return _blocks[blockNumber];
    }

    function txOpCount(BlockNumber blockNumber, uint32 txSeq) public view returns (uint32) {
        return _txOpCount[EntityHashing.txKey(blockNumber, txSeq)];
    }

    function commitment(bytes32 key) public view returns (EntityHashing.Commitment memory) {
        return _commitments[key];
    }

    function nonces(address owner) public view returns (uint32) {
        return _nonces[owner];
    }

    // -------------------------------------------------------------------------
    // Internal functions — entity hash (requires domain separator)
    // -------------------------------------------------------------------------

    /// @dev Domain-wrap an entity struct hash. Used by both _computeEntityHash
    /// and operations that recompute entityHash without changing coreHash (extend, transfer).
    function _wrapEntityHash(bytes32 coreHash_, address owner, BlockNumber updatedAt, BlockNumber expiresAt)
        internal
        view
        virtual
        returns (bytes32)
    {
        return _hashTypedDataV4(EntityHashing.entityStructHash(coreHash_, owner, updatedAt, expiresAt));
    }

    /// @dev Compute the two-level EIP-712 hash:
    ///   coreHash: immutable content identity (key, creator, createdAt, content)
    ///   entityHash: domain-wrapped hash of (coreHash, owner, updatedAt, expiresAt)
    function _computeEntityHash(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        address owner,
        BlockNumber updatedAt,
        BlockNumber expiresAt,
        EntityHashing.Op calldata op
    ) internal view virtual returns (bytes32 coreHash_, bytes32 entityHash_) {
        coreHash_ = EntityHashing.coreHash(key, creator, createdAt, op.contentType, op.payload, op.attributes);
        entityHash_ = _wrapEntityHash(coreHash_, owner, updatedAt, expiresAt);
    }

    /// @dev Mint a new entity key by post-incrementing the owner's nonce.
    /// Uniqueness is guaranteed by the monotonic nonce — no existence check needed.
    function _createEntityKey(address owner) internal virtual returns (bytes32) {
        uint32 nonce = _nonces[owner]++;
        return EntityHashing.entityKey(block.chainid, address(this), owner, nonce);
    }

    // -------------------------------------------------------------------------
    // Internal functions — dispatch
    // -------------------------------------------------------------------------

    /// @dev Route an op to the correct handler by opType.
    /// Reverts with InvalidOpType for unrecognised values.
    function _dispatch(EntityHashing.Op calldata op, BlockNumber current)
        internal
        virtual
        returns (bytes32 key, bytes32 entityHash_)
    {
        uint8 opType = op.opType;
        if (opType == EntityHashing.CREATE) return _create(op, current);
        if (opType == EntityHashing.UPDATE) return _update(op, current);
        if (opType == EntityHashing.EXTEND) return _extend(op, current);
        if (opType == EntityHashing.TRANSFER) return _transfer(op, current);
        if (opType == EntityHashing.DELETE) return _delete(op, current);
        if (opType == EntityHashing.EXPIRE) return _expire(op, current);
        revert EntityHashing.InvalidOpType(opType);
    }

    // -------------------------------------------------------------------------
    // Internal functions — entity operations
    // -------------------------------------------------------------------------

    /// @dev Create a new entity. Mints a deterministic key from the caller's
    /// nonce, computes the two-level EIP-712 hash, and stores a minimal
    /// on-chain commitment. Full entity data lives in calldata.
    ///
    /// Validation:
    ///   1. contentType must be valid MIME
    ///   2. expiresAt must be strictly in the future
    ///   3. Attributes validated inside coreHash (count, sorting, value type/length)
    function _create(EntityHashing.Op calldata op, BlockNumber current)
        internal
        virtual
        returns (bytes32 key, bytes32 entityHash_)
    {
        validateMime128(op.contentType);
        EntityHashing.requireFutureExpiry(op.expiresAt, current);

        key = _createEntityKey(msg.sender);

        bytes32 coreHash_;
        (coreHash_, entityHash_) = _computeEntityHash(key, msg.sender, current, msg.sender, current, op.expiresAt, op);

        _commitments[key] = EntityHashing.Commitment({
            creator: msg.sender,
            createdAt: current,
            updatedAt: current,
            expiresAt: op.expiresAt,
            owner: msg.sender,
            coreHash: coreHash_
        });

        emit EntityOp(key, EntityHashing.CREATE, msg.sender, op.expiresAt, entityHash_);
    }

    /// @dev Update an existing entity's payload, contentType, and attributes.
    /// Does not change owner or expiry. The coreHash is fully recomputed from
    /// the new content and the entity's immutable fields (key, creator, createdAt).
    ///
    /// Validation:
    ///   1. Entity must exist and be active
    ///   2. Caller must be the owner
    ///   3. contentType must be valid MIME
    ///   4. Attributes validated inside coreHash (count, sorting, value type/length)
    function _update(EntityHashing.Op calldata op, BlockNumber current) internal virtual returns (bytes32, bytes32) {
        bytes32 key = op.entityKey;
        EntityHashing.Commitment storage c = _commitments[key];

        EntityHashing.requireExists(key, c);
        EntityHashing.requireActive(key, c, current);
        EntityHashing.requireOwner(key, c);

        validateMime128(op.contentType);

        (bytes32 coreHash_, bytes32 entityHash_) =
            _computeEntityHash(key, c.creator, c.createdAt, c.owner, current, c.expiresAt, op);

        c.coreHash = coreHash_;
        c.updatedAt = current;

        emit EntityOp(key, EntityHashing.UPDATE, c.owner, c.expiresAt, entityHash_);
        return (key, entityHash_);
    }

    /// @dev Extend an entity's expiry. Does not change payload, attributes, or owner.
    /// The entityHash is recomputed from the stored coreHash with the new expiresAt.
    ///
    /// Validation:
    ///   1. Entity must exist and be active
    ///   2. Caller must be the owner
    ///   3. New expiresAt must be strictly greater than current expiresAt
    function _extend(EntityHashing.Op calldata op, BlockNumber current) internal virtual returns (bytes32, bytes32) {
        bytes32 key = op.entityKey;
        EntityHashing.Commitment storage c = _commitments[key];

        EntityHashing.requireExists(key, c);
        EntityHashing.requireActive(key, c, current);
        EntityHashing.requireOwner(key, c);
        EntityHashing.requireExpiryIncreased(key, op.expiresAt, c.expiresAt);

        c.expiresAt = op.expiresAt;
        c.updatedAt = current;

        bytes32 entityHash_ = _wrapEntityHash(c.coreHash, c.owner, current, op.expiresAt);

        emit EntityOp(key, EntityHashing.EXTEND, c.owner, op.expiresAt, entityHash_);
        return (key, entityHash_);
    }

    /// @dev Transfer entity ownership. Does not change payload, attributes, or expiry.
    /// The entityHash is recomputed from the stored coreHash with the new owner.
    ///
    /// Validation:
    ///   1. Entity must exist and be active
    ///   2. Caller must be the current owner
    ///   3. New owner must not be the zero address or current owner
    function _transfer(EntityHashing.Op calldata op, BlockNumber current) internal virtual returns (bytes32, bytes32) {
        bytes32 key = op.entityKey;
        EntityHashing.Commitment storage c = _commitments[key];

        EntityHashing.requireExists(key, c);
        EntityHashing.requireActive(key, c, current);
        EntityHashing.requireOwner(key, c);
        EntityHashing.requireNonZeroAddress(key, op.newOwner);
        EntityHashing.requireNewOwner(key, op.newOwner, c.owner);

        c.owner = op.newOwner;
        c.updatedAt = current;

        bytes32 entityHash_ = _wrapEntityHash(c.coreHash, op.newOwner, current, c.expiresAt);

        emit EntityOp(key, EntityHashing.TRANSFER, op.newOwner, c.expiresAt, entityHash_);
        return (key, entityHash_);
    }

    /// @dev Delete an entity before its expiry. Owner-initiated.
    /// Snapshots the entityHash before zeroing the commitment.
    ///
    /// Validation:
    ///   1. Entity must exist and be active
    ///   2. Caller must be the owner
    function _delete(EntityHashing.Op calldata op, BlockNumber current) internal virtual returns (bytes32, bytes32) {
        bytes32 key = op.entityKey;
        EntityHashing.Commitment storage c = _commitments[key];

        EntityHashing.requireExists(key, c);
        EntityHashing.requireActive(key, c, current);
        EntityHashing.requireOwner(key, c);

        // Snapshot before deletion.
        bytes32 entityHash_ = _wrapEntityHash(c.coreHash, c.owner, c.updatedAt, c.expiresAt);
        address owner = c.owner;
        BlockNumber expiresAt = c.expiresAt;

        delete _commitments[key];

        emit EntityOp(key, EntityHashing.DELETE, owner, expiresAt, entityHash_);
        return (key, entityHash_);
    }

    /// @dev Remove an expired entity from storage. Callable by anyone.
    /// Snapshots the entityHash before zeroing the commitment.
    ///
    /// Validation:
    ///   1. Entity must exist
    ///   2. Entity must have expired (expiresAt <= current)
    function _expire(EntityHashing.Op calldata op, BlockNumber current) internal virtual returns (bytes32, bytes32) {
        bytes32 key = op.entityKey;
        EntityHashing.Commitment storage c = _commitments[key];

        EntityHashing.requireExists(key, c);
        EntityHashing.requireExpired(key, c, current);

        bytes32 entityHash_ = _wrapEntityHash(c.coreHash, c.owner, c.updatedAt, c.expiresAt);
        address owner = c.owner;
        BlockNumber expiresAt = c.expiresAt;

        delete _commitments[key];

        emit EntityOp(key, EntityHashing.EXPIRE, owner, expiresAt, entityHash_);
        return (key, entityHash_);
    }
}
