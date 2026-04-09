// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "./BlockNumber.sol";
import {ShortString} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {EntityHashing, OpKey, TxKey} from "./EntityHashing.sol";

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

    mapping(address owner => uint32) public nonces;

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
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant MAX_PAYLOAD_SIZE = 24_576;
    uint256 public constant MAX_ATTRIBUTES = 32;
    uint256 public constant MAX_STRING_ATTR_SIZE = 1024;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event EntityCreated(
        bytes32 indexed entityKey,
        address indexed owner,
        bytes32 entityHash,
        BlockNumber expiresAt,
        bytes payload,
        string contentType,
        EntityHashing.Attribute[] attributes
    );

    // -------------------------------------------------------------------------
    // State — linked list pointers
    // -------------------------------------------------------------------------

    BlockNumber internal immutable _genesisBlock;

    // _headBlock: most recent block with mutations (head of linked list)
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

        // Read previous hash from the head of the chain.
        bytes32 hash = changeSetHash();

        // Block transition: maintain the block-level linked list.
        // _headBlock is initialised to the deploy block (sentinel anchor),
        // so it is always non-zero when we reach this point.
        // nextBlock == 0 on the head node means "end of chain."
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

        // Process ops — one SSTORE per op for the snapshot.
        for (uint32 opSeq = 0; opSeq < ops.length; opSeq++) {
            uint8 opType = ops[opSeq].opType;
            bytes32 key;
            bytes32 entityHash_;

            if (opType == EntityHashing.CREATE) {
                (key, entityHash_) = _create(ops[opSeq], current);
            } else if (opType == EntityHashing.UPDATE) {
                (key, entityHash_) = _update(ops[opSeq], current);
            } else if (opType == EntityHashing.EXTEND) {
                (key, entityHash_) = _extend(ops[opSeq], current);
            } else if (opType == EntityHashing.TRANSFER) {
                (key, entityHash_) = _transfer(ops[opSeq], current);
            } else if (opType == EntityHashing.DELETE) {
                (key, entityHash_) = _delete(ops[opSeq], current);
            } else if (opType == EntityHashing.EXPIRE) {
                (key, entityHash_) = _expire(ops[opSeq].entityKey, current);
            } else {
                // TODO should not reach here
            }

            hash = EntityHashing.chainOp(hash, opType, key, entityHash_);
            _hashAt[EntityHashing.opKey(current, txSeq, opSeq)] = hash;
        }

        // Record op count for this tx.
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

    function getCommitment(bytes32 key) public view returns (EntityHashing.Commitment memory) {
        return _commitments[key];
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
    // Internal functions — entity operations
    // -------------------------------------------------------------------------

    function _create(EntityHashing.Op calldata op, BlockNumber current) internal returns (bytes32 key, bytes32 entityHash_) {
        // Validate payload size.
        if (op.payload.length > MAX_PAYLOAD_SIZE) {
            revert EntityHashing.PayloadTooLarge(op.payload.length, MAX_PAYLOAD_SIZE);
        }

        // Validate attribute count.
        if (op.attributes.length > MAX_ATTRIBUTES) {
            revert EntityHashing.TooManyAttributes(op.attributes.length, MAX_ATTRIBUTES);
        }

        // Validate attributes: non-empty names, strict ascending order, string size limits.
        for (uint256 i = 0; i < op.attributes.length; i++) {
            bytes32 name = ShortString.unwrap(op.attributes[i].name);

            if (name == bytes32(0)) {
                revert EntityHashing.EmptyAttributeName(i);
            }

            if (i > 0) {
                bytes32 prev = ShortString.unwrap(op.attributes[i - 1].name);
                if (name <= prev) {
                    revert EntityHashing.AttributesNotSorted(name, prev);
                }
            }

            if (op.attributes[i].valueType == EntityHashing.AttributeType.STRING) {
                if (op.attributes[i].fixedValue != bytes32(0)) {
                    revert EntityHashing.NonCanonicalAttribute(i);
                }
                if (bytes(op.attributes[i].stringValue).length > MAX_STRING_ATTR_SIZE) {
                    revert EntityHashing.StringAttributeTooLarge(
                        name, bytes(op.attributes[i].stringValue).length, MAX_STRING_ATTR_SIZE
                    );
                }
            } else {
                if (bytes(op.attributes[i].stringValue).length != 0) {
                    revert EntityHashing.NonCanonicalAttribute(i);
                }
            }
        }

        // Validate expiry.
        if (op.expiresAt <= current) {
            revert EntityHashing.ExpiryInPast(op.expiresAt, current);
        }

        // Mint entity key from owner nonce.
        uint32 nonce = nonces[msg.sender]++;
        key = EntityHashing.entityKey(block.chainid, address(this), msg.sender, nonce);

        // Entity key must not already exist (nonce should guarantee this,
        // but defensive check against storage collision).
        if (_commitments[key].creator != address(0)) {
            revert EntityHashing.EntityAlreadyExists(key);
        }

        // Compute hashes.
        bytes32 coreHash_ =
            EntityHashing.coreHash(key, msg.sender, current, op.contentType, op.payload, op.attributes);
        entityHash_ = _entityHash(coreHash_, msg.sender, current, op.expiresAt);

        // Store commitment (no payload/attributes — those live in calldata/events).
        _commitments[key] = EntityHashing.Commitment({
            creator: msg.sender,
            createdAt: current,
            updatedAt: current,
            expiresAt: op.expiresAt,
            owner: msg.sender,
            coreHash: coreHash_
        });

        emit EntityCreated(key, msg.sender, entityHash_, op.expiresAt, op.payload, op.contentType, op.attributes);
    }

    function _update(EntityHashing.Op calldata op, BlockNumber current) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner, content type, payload, attributes (same as create)
        // Then: recompute coreHash from new content, update entity, recompute entityHash
        revert("not implemented");
    }

    function _extend(EntityHashing.Op calldata op, BlockNumber current) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner, new expiresAt > current expiresAt
        // Then: update expiresAt + updatedAt, recompute entityHash from stored coreHash
        revert("not implemented");
    }

    function _transfer(EntityHashing.Op calldata op, BlockNumber current) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner, newOwner != address(0)
        // Then: set owner to newOwner + updatedAt, recompute entityHash from stored coreHash
        revert("not implemented");
    }

    function _delete(EntityHashing.Op calldata op, BlockNumber current) internal returns (bytes32, bytes32) {
        // Validates: entity exists + not expired + msg.sender is owner
        // Then: snapshot entityHash before deletion, delete entity
        revert("not implemented");
    }

    function _expire(bytes32 key, BlockNumber current) internal returns (bytes32, bytes32) {
        // Validates: entity exists + currentBlock >= expiresAt (entity has expired)
        // Then: snapshot entityHash before deletion, delete entity (callable by anyone)
        revert("not implemented");
    }
}
