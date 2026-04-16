// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber, currentBlock} from "../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Entity} from "../../src/Entity.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {encodeMime128} from "../../src/types/Mime128.sol";

/// @dev Tests the execute() function's hash chaining, block linked list
/// maintenance, and per-op snapshot storage. Dispatch is stubbed to return
/// deterministic values so the test focuses on execute's own logic.
contract ExecuteTest is Test, EntityRegistry {
    // Stub tracking — each _dispatch call pops the next (key, hash) pair.
    bytes32[] internal _stubKeys;
    bytes32[] internal _stubHashes;
    uint256 internal _stubIndex;
    uint256 internal _stubSeed;

    function _dispatch(Entity.Operation calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        bytes32 key = _stubKeys[_stubIndex];
        bytes32 hash = _stubHashes[_stubIndex];
        _stubIndex++;
        return (key, hash);
    }

    /// @dev Push expected (key, hash) pairs for the next execute call.
    /// Uses a global seed so stubs are unique across multiple pushes.
    function _pushStubs(uint256 count) internal {
        delete _stubKeys;
        delete _stubHashes;
        _stubIndex = 0;
        for (uint256 i = 0; i < count; i++) {
            _stubKeys.push(keccak256(abi.encode("key", _stubSeed + i)));
            _stubHashes.push(keccak256(abi.encode("hash", _stubSeed + i)));
        }
        _stubSeed += count;
    }

    /// @dev Build a minimal Operation with a given operationType.
    function _op(uint8 operationType) internal pure returns (Entity.Operation memory) {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        return Entity.Operation({
            operationType: operationType,
            entityKey: bytes32(0),
            payload: "",
            contentType: encodeMime128("text/plain"),
            attributes: attrs,
            expiresAt: BlockNumber.wrap(0),
            newOwner: address(0)
        });
    }

    // =========================================================================
    // Validation — empty batch
    // =========================================================================

    function test_execute_emptyBatch_reverts() public {
        Entity.Operation[] memory ops = new Entity.Operation[](0);
        vm.expectRevert(Entity.EmptyBatch.selector);
        this.execute(ops);
    }

    // =========================================================================
    // Hash chaining — single op
    // =========================================================================

    function test_execute_singleOp_changeSetHashUpdated() public {
        assertEq(changeSetHash(), bytes32(0));

        _pushStubs(1);
        bytes32 k = _stubKeys[0];
        bytes32 h = _stubHashes[0];

        Entity.Operation[] memory ops = new Entity.Operation[](1);
        ops[0] = _op(Entity.CREATE);
        this.execute(ops);

        bytes32 expected = Entity.chainOperationHash(bytes32(0), Entity.CREATE, k, h);
        assertEq(changeSetHash(), expected);
    }

    // =========================================================================
    // Hash chaining — multi-op batch
    // =========================================================================

    function test_execute_multiOp_chainsHashesSequentially() public {
        _pushStubs(3);
        bytes32 k0 = _stubKeys[0];
        bytes32 h0 = _stubHashes[0];
        bytes32 k1 = _stubKeys[1];
        bytes32 h1 = _stubHashes[1];
        bytes32 k2 = _stubKeys[2];
        bytes32 h2 = _stubHashes[2];

        Entity.Operation[] memory ops = new Entity.Operation[](3);
        ops[0] = _op(Entity.CREATE);
        ops[1] = _op(Entity.UPDATE);
        ops[2] = _op(Entity.DELETE);
        this.execute(ops);

        bytes32 chain0 = Entity.chainOperationHash(bytes32(0), Entity.CREATE, k0, h0);
        bytes32 chain1 = Entity.chainOperationHash(chain0, Entity.UPDATE, k1, h1);
        bytes32 chain2 = Entity.chainOperationHash(chain1, Entity.DELETE, k2, h2);

        assertEq(changeSetHash(), chain2);
    }

    // =========================================================================
    // Per-op hash snapshots
    // =========================================================================

    function test_execute_storesPerOpSnapshots() public {
        _pushStubs(3);
        bytes32 k0 = _stubKeys[0];
        bytes32 h0 = _stubHashes[0];
        bytes32 k1 = _stubKeys[1];
        bytes32 h1 = _stubHashes[1];
        bytes32 k2 = _stubKeys[2];
        bytes32 h2 = _stubHashes[2];

        Entity.Operation[] memory ops = new Entity.Operation[](3);
        ops[0] = _op(Entity.CREATE);
        ops[1] = _op(Entity.UPDATE);
        ops[2] = _op(Entity.DELETE);
        this.execute(ops);

        BlockNumber current = currentBlock();
        bytes32 chain0 = Entity.chainOperationHash(bytes32(0), Entity.CREATE, k0, h0);
        bytes32 chain1 = Entity.chainOperationHash(chain0, Entity.UPDATE, k1, h1);
        bytes32 chain2 = Entity.chainOperationHash(chain1, Entity.DELETE, k2, h2);

        assertEq(changeSetHashAtOp(current, 0, 0), chain0);
        assertEq(changeSetHashAtOp(current, 0, 1), chain1);
        assertEq(changeSetHashAtOp(current, 0, 2), chain2);
    }

    // =========================================================================
    // txOpCount
    // =========================================================================

    function test_execute_recordsTxOpCount() public {
        _pushStubs(3);
        Entity.Operation[] memory ops = new Entity.Operation[](3);
        ops[0] = _op(Entity.CREATE);
        ops[1] = _op(Entity.UPDATE);
        ops[2] = _op(Entity.DELETE);
        this.execute(ops);

        assertEq(txOpCount(currentBlock(), 0), 3);
    }

    function test_execute_singleOp_txOpCountIsOne() public {
        _pushStubs(1);
        Entity.Operation[] memory ops = new Entity.Operation[](1);
        ops[0] = _op(Entity.CREATE);
        this.execute(ops);

        assertEq(txOpCount(currentBlock(), 0), 1);
    }

    // =========================================================================
    // Block linked list — first execute in a new block
    // =========================================================================

    function test_execute_newBlock_headBlockUpdated() public {
        vm.roll(block.number + 10);
        BlockNumber newBlock = currentBlock();

        _pushStubs(1);
        Entity.Operation[] memory ops = new Entity.Operation[](1);
        ops[0] = _op(Entity.CREATE);
        this.execute(ops);

        assertEq(BlockNumber.unwrap(headBlock()), BlockNumber.unwrap(newBlock));
    }

    function test_execute_newBlock_linkedListPointers() public {
        BlockNumber deployBlock = currentBlock();
        vm.roll(block.number + 10);
        BlockNumber newBlock = currentBlock();

        _pushStubs(1);
        Entity.Operation[] memory ops = new Entity.Operation[](1);
        ops[0] = _op(Entity.CREATE);
        this.execute(ops);

        Entity.BlockNode memory deployNode = getBlockNode(deployBlock);
        assertEq(BlockNumber.unwrap(deployNode.nextBlock), BlockNumber.unwrap(newBlock));

        Entity.BlockNode memory newNode = getBlockNode(newBlock);
        assertEq(BlockNumber.unwrap(newNode.prevBlock), BlockNumber.unwrap(deployBlock));
    }

    function test_execute_newBlock_txCountIsOne() public {
        vm.roll(block.number + 10);

        _pushStubs(1);
        Entity.Operation[] memory ops = new Entity.Operation[](1);
        ops[0] = _op(Entity.CREATE);
        this.execute(ops);

        Entity.BlockNode memory node = getBlockNode(currentBlock());
        assertEq(node.txCount, 1);
    }

    // =========================================================================
    // Block linked list — same block, multiple txs
    // =========================================================================

    function test_execute_sameBlock_txCountIncrements() public {
        vm.roll(block.number + 10);

        _pushStubs(1);
        Entity.Operation[] memory ops1 = new Entity.Operation[](1);
        ops1[0] = _op(Entity.CREATE);
        this.execute(ops1);

        assertEq(getBlockNode(currentBlock()).txCount, 1);

        _pushStubs(1);
        Entity.Operation[] memory ops2 = new Entity.Operation[](1);
        ops2[0] = _op(Entity.CREATE);
        this.execute(ops2);

        assertEq(getBlockNode(currentBlock()).txCount, 2);
    }

    function test_execute_sameBlock_secondTx_correctOpCounts() public {
        vm.roll(block.number + 10);
        BlockNumber current = currentBlock();

        // First tx — 2 ops.
        _pushStubs(2);
        Entity.Operation[] memory ops1 = new Entity.Operation[](2);
        ops1[0] = _op(Entity.CREATE);
        ops1[1] = _op(Entity.UPDATE);
        this.execute(ops1);

        // Second tx — 1 op.
        _pushStubs(1);
        Entity.Operation[] memory ops2 = new Entity.Operation[](1);
        ops2[0] = _op(Entity.DELETE);
        this.execute(ops2);

        assertEq(txOpCount(current, 0), 2);
        assertEq(txOpCount(current, 1), 1);
    }

    function test_execute_sameBlock_hashChainContinuesAcrossTxs() public {
        vm.roll(block.number + 10);

        _pushStubs(1);
        Entity.Operation[] memory ops1 = new Entity.Operation[](1);
        ops1[0] = _op(Entity.CREATE);
        this.execute(ops1);
        bytes32 hashAfterTx1 = changeSetHash();

        _pushStubs(1);
        bytes32 k1 = _stubKeys[0];
        bytes32 h1 = _stubHashes[0];
        Entity.Operation[] memory ops2 = new Entity.Operation[](1);
        ops2[0] = _op(Entity.UPDATE);
        this.execute(ops2);

        bytes32 expected = Entity.chainOperationHash(hashAfterTx1, Entity.UPDATE, k1, h1);
        assertEq(changeSetHash(), expected);
    }

    // =========================================================================
    // Block linked list — cross-block transitions
    // =========================================================================

    function test_execute_crossBlock_linkedListMaintained() public {
        BlockNumber deployBlock = currentBlock();

        vm.roll(block.number + 10);
        BlockNumber blockA = currentBlock();
        _pushStubs(1);
        Entity.Operation[] memory ops1 = new Entity.Operation[](1);
        ops1[0] = _op(Entity.CREATE);
        this.execute(ops1);

        vm.roll(block.number + 5);
        BlockNumber blockB = currentBlock();
        _pushStubs(1);
        Entity.Operation[] memory ops2 = new Entity.Operation[](1);
        ops2[0] = _op(Entity.CREATE);
        this.execute(ops2);

        // deployBlock → blockA → blockB
        Entity.BlockNode memory deployNode = getBlockNode(deployBlock);
        assertEq(BlockNumber.unwrap(deployNode.nextBlock), BlockNumber.unwrap(blockA));

        Entity.BlockNode memory nodeA = getBlockNode(blockA);
        assertEq(BlockNumber.unwrap(nodeA.prevBlock), BlockNumber.unwrap(deployBlock));
        assertEq(BlockNumber.unwrap(nodeA.nextBlock), BlockNumber.unwrap(blockB));

        Entity.BlockNode memory nodeB = getBlockNode(blockB);
        assertEq(BlockNumber.unwrap(nodeB.prevBlock), BlockNumber.unwrap(blockA));
        assertEq(BlockNumber.unwrap(nodeB.nextBlock), 0);
    }

    function test_execute_crossBlock_headBlockUpdates() public {
        vm.roll(block.number + 10);
        BlockNumber blockA = currentBlock();
        _pushStubs(1);
        Entity.Operation[] memory ops1 = new Entity.Operation[](1);
        ops1[0] = _op(Entity.CREATE);
        this.execute(ops1);
        assertEq(BlockNumber.unwrap(headBlock()), BlockNumber.unwrap(blockA));

        vm.roll(block.number + 5);
        BlockNumber blockB = currentBlock();
        _pushStubs(1);
        Entity.Operation[] memory ops2 = new Entity.Operation[](1);
        ops2[0] = _op(Entity.CREATE);
        this.execute(ops2);
        assertEq(BlockNumber.unwrap(headBlock()), BlockNumber.unwrap(blockB));
    }

    function test_execute_crossBlock_hashChainContinues() public {
        _pushStubs(1);
        Entity.Operation[] memory ops1 = new Entity.Operation[](1);
        ops1[0] = _op(Entity.CREATE);
        this.execute(ops1);
        bytes32 hashAfterBlock1 = changeSetHash();

        vm.roll(block.number + 1);
        _pushStubs(1);
        bytes32 k1 = _stubKeys[0];
        bytes32 h1 = _stubHashes[0];
        Entity.Operation[] memory ops2 = new Entity.Operation[](1);
        ops2[0] = _op(Entity.UPDATE);
        this.execute(ops2);

        bytes32 expected = Entity.chainOperationHash(hashAfterBlock1, Entity.UPDATE, k1, h1);
        assertEq(changeSetHash(), expected);
    }

    // =========================================================================
    // changeSetHash view functions
    // =========================================================================

    function test_changeSetHashAtBlock_returnsLastOpHash() public {
        vm.roll(block.number + 10);
        BlockNumber current = currentBlock();

        _pushStubs(3);
        bytes32 k0 = _stubKeys[0];
        bytes32 h0 = _stubHashes[0];
        bytes32 k1 = _stubKeys[1];
        bytes32 h1 = _stubHashes[1];
        bytes32 k2 = _stubKeys[2];
        bytes32 h2 = _stubHashes[2];

        Entity.Operation[] memory ops = new Entity.Operation[](3);
        ops[0] = _op(Entity.CREATE);
        ops[1] = _op(Entity.UPDATE);
        ops[2] = _op(Entity.DELETE);
        this.execute(ops);

        bytes32 chain0 = Entity.chainOperationHash(bytes32(0), Entity.CREATE, k0, h0);
        bytes32 chain1 = Entity.chainOperationHash(chain0, Entity.UPDATE, k1, h1);
        bytes32 chain2 = Entity.chainOperationHash(chain1, Entity.DELETE, k2, h2);

        assertEq(changeSetHashAtBlock(current), chain2);
    }

    function test_changeSetHashAtTx_returnsLastOpHashOfEachTx() public {
        vm.roll(block.number + 10);
        BlockNumber current = currentBlock();

        // tx0: 2 ops.
        _pushStubs(2);
        bytes32 tx0k0 = _stubKeys[0];
        bytes32 tx0h0 = _stubHashes[0];
        bytes32 tx0k1 = _stubKeys[1];
        bytes32 tx0h1 = _stubHashes[1];
        Entity.Operation[] memory ops1 = new Entity.Operation[](2);
        ops1[0] = _op(Entity.CREATE);
        ops1[1] = _op(Entity.UPDATE);
        this.execute(ops1);

        // tx1: 1 op.
        _pushStubs(1);
        bytes32 tx1k0 = _stubKeys[0];
        bytes32 tx1h0 = _stubHashes[0];
        Entity.Operation[] memory ops2 = new Entity.Operation[](1);
        ops2[0] = _op(Entity.DELETE);
        this.execute(ops2);

        bytes32 chain0 = Entity.chainOperationHash(bytes32(0), Entity.CREATE, tx0k0, tx0h0);
        bytes32 chain1 = Entity.chainOperationHash(chain0, Entity.UPDATE, tx0k1, tx0h1);
        assertEq(changeSetHashAtTx(current, 0), chain1);

        bytes32 chain2 = Entity.chainOperationHash(chain1, Entity.DELETE, tx1k0, tx1h0);
        assertEq(changeSetHashAtTx(current, 1), chain2);
    }

    function test_changeSetHashAtBlock_uninitializedBlock_returnsZero() public view {
        assertEq(changeSetHashAtBlock(BlockNumber.wrap(999999)), bytes32(0));
    }

    function test_changeSetHashAtTx_uninitializedTx_returnsZero() public view {
        assertEq(changeSetHashAtTx(BlockNumber.wrap(999999), 0), bytes32(0));
    }

    // =========================================================================
    // Execute at deploy block (no block transition)
    // =========================================================================

    function test_execute_atDeployBlock_noBlockTransition() public {
        BlockNumber deployBlock = currentBlock();

        _pushStubs(1);
        Entity.Operation[] memory ops = new Entity.Operation[](1);
        ops[0] = _op(Entity.CREATE);
        this.execute(ops);

        assertEq(BlockNumber.unwrap(headBlock()), BlockNumber.unwrap(deployBlock));
        assertEq(getBlockNode(deployBlock).txCount, 1);
    }

    // =========================================================================
    // changeSetHash() returns zero before any execute
    // =========================================================================

    function test_changeSetHash_initiallyZero() public view {
        assertEq(changeSetHash(), bytes32(0));
    }

    // =========================================================================
    // genesisBlock and headBlock after deployment
    // =========================================================================

    function test_genesisBlock_equalsDeployBlock() public view {
        assertEq(BlockNumber.unwrap(genesisBlock()), uint32(block.number));
    }

    function test_headBlock_initiallyEqualsGenesisBlock() public view {
        assertEq(BlockNumber.unwrap(headBlock()), BlockNumber.unwrap(genesisBlock()));
    }
}
