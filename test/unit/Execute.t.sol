// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {encodeMime128} from "../../src/types/Mime128.sol";

/// @dev Tests the execute() function's routing, hash chaining, block linked
/// list maintenance, and per-op snapshot storage. Internal ops are stubbed
/// to return deterministic values so the test focuses on execute's own logic.
contract ExecuteTest is Test, EntityRegistry {
    // Stub tracking — each internal op call pops the next (key, hash) pair.
    bytes32[] internal _stubKeys;
    bytes32[] internal _stubHashes;
    uint256 internal _stubIndex;
    uint256 internal _stubSeed;

    function _nextStub() internal returns (bytes32 key, bytes32 hash) {
        key = _stubKeys[_stubIndex];
        hash = _stubHashes[_stubIndex];
        _stubIndex++;
    }

    function _create(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        return _nextStub();
    }

    function _update(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        return _nextStub();
    }

    function _extend(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        return _nextStub();
    }

    function _transfer(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        return _nextStub();
    }

    function _delete(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        return _nextStub();
    }

    function _expire(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        return _nextStub();
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

    /// @dev Build a minimal Op with a given opType.
    function _op(uint8 opType) internal pure returns (EntityHashing.Op memory) {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        return EntityHashing.Op({
            opType: opType,
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
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](0);
        vm.expectRevert(EntityHashing.EmptyBatch.selector);
        this.execute(ops);
    }

    // =========================================================================
    // Validation — invalid op type
    // =========================================================================

    function test_execute_opTypeZero_reverts() public {
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.UNINITIALIZED);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.InvalidOpType.selector, uint8(0)));
        this.execute(ops);
    }

    function test_execute_opTypeSeven_reverts() public {
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(7);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.InvalidOpType.selector, uint8(7)));
        this.execute(ops);
    }

    function test_execute_opType255_reverts() public {
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(255);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.InvalidOpType.selector, uint8(255)));
        this.execute(ops);
    }

    // =========================================================================
    // Routing — each op type dispatches correctly
    // =========================================================================

    function test_execute_routesCreate() public {
        _pushStubs(1);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.CREATE);
        this.execute(ops);
        assertEq(_stubIndex, 1);
    }

    function test_execute_routesUpdate() public {
        _pushStubs(1);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.UPDATE);
        this.execute(ops);
        assertEq(_stubIndex, 1);
    }

    function test_execute_routesExtend() public {
        _pushStubs(1);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.EXTEND);
        this.execute(ops);
        assertEq(_stubIndex, 1);
    }

    function test_execute_routesTransfer() public {
        _pushStubs(1);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.TRANSFER);
        this.execute(ops);
        assertEq(_stubIndex, 1);
    }

    function test_execute_routesDelete() public {
        _pushStubs(1);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.DELETE);
        this.execute(ops);
        assertEq(_stubIndex, 1);
    }

    function test_execute_routesExpire() public {
        _pushStubs(1);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.EXPIRE);
        this.execute(ops);
        assertEq(_stubIndex, 1);
    }

    // =========================================================================
    // Hash chaining — single op
    // =========================================================================

    function test_execute_singleOp_changeSetHashUpdated() public {
        assertEq(changeSetHash(), bytes32(0));

        _pushStubs(1);
        bytes32 k = _stubKeys[0];
        bytes32 h = _stubHashes[0];

        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.CREATE);
        this.execute(ops);

        bytes32 expected = EntityHashing.chainOp(bytes32(0), EntityHashing.CREATE, k, h);
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

        EntityHashing.Op[] memory ops = new EntityHashing.Op[](3);
        ops[0] = _op(EntityHashing.CREATE);
        ops[1] = _op(EntityHashing.UPDATE);
        ops[2] = _op(EntityHashing.DELETE);
        this.execute(ops);

        bytes32 chain0 = EntityHashing.chainOp(bytes32(0), EntityHashing.CREATE, k0, h0);
        bytes32 chain1 = EntityHashing.chainOp(chain0, EntityHashing.UPDATE, k1, h1);
        bytes32 chain2 = EntityHashing.chainOp(chain1, EntityHashing.DELETE, k2, h2);

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

        EntityHashing.Op[] memory ops = new EntityHashing.Op[](3);
        ops[0] = _op(EntityHashing.CREATE);
        ops[1] = _op(EntityHashing.UPDATE);
        ops[2] = _op(EntityHashing.DELETE);
        this.execute(ops);

        BlockNumber current = currentBlock();
        bytes32 chain0 = EntityHashing.chainOp(bytes32(0), EntityHashing.CREATE, k0, h0);
        bytes32 chain1 = EntityHashing.chainOp(chain0, EntityHashing.UPDATE, k1, h1);
        bytes32 chain2 = EntityHashing.chainOp(chain1, EntityHashing.DELETE, k2, h2);

        assertEq(changeSetHashAtOp(current, 0, 0), chain0);
        assertEq(changeSetHashAtOp(current, 0, 1), chain1);
        assertEq(changeSetHashAtOp(current, 0, 2), chain2);
    }

    // =========================================================================
    // txOpCount
    // =========================================================================

    function test_execute_recordsTxOpCount() public {
        _pushStubs(3);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](3);
        ops[0] = _op(EntityHashing.CREATE);
        ops[1] = _op(EntityHashing.UPDATE);
        ops[2] = _op(EntityHashing.DELETE);
        this.execute(ops);

        assertEq(txOpCount(currentBlock(), 0), 3);
    }

    function test_execute_singleOp_txOpCountIsOne() public {
        _pushStubs(1);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.CREATE);
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
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.CREATE);
        this.execute(ops);

        assertEq(BlockNumber.unwrap(headBlock()), BlockNumber.unwrap(newBlock));
    }

    function test_execute_newBlock_linkedListPointers() public {
        BlockNumber deployBlock = currentBlock();
        vm.roll(block.number + 10);
        BlockNumber newBlock = currentBlock();

        _pushStubs(1);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.CREATE);
        this.execute(ops);

        EntityHashing.BlockNode memory deployNode = getBlockNode(deployBlock);
        assertEq(BlockNumber.unwrap(deployNode.nextBlock), BlockNumber.unwrap(newBlock));

        EntityHashing.BlockNode memory newNode = getBlockNode(newBlock);
        assertEq(BlockNumber.unwrap(newNode.prevBlock), BlockNumber.unwrap(deployBlock));
    }

    function test_execute_newBlock_txCountIsOne() public {
        vm.roll(block.number + 10);

        _pushStubs(1);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.CREATE);
        this.execute(ops);

        EntityHashing.BlockNode memory node = getBlockNode(currentBlock());
        assertEq(node.txCount, 1);
    }

    // =========================================================================
    // Block linked list — same block, multiple txs
    // =========================================================================

    function test_execute_sameBlock_txCountIncrements() public {
        vm.roll(block.number + 10);

        _pushStubs(1);
        EntityHashing.Op[] memory ops1 = new EntityHashing.Op[](1);
        ops1[0] = _op(EntityHashing.CREATE);
        this.execute(ops1);

        assertEq(getBlockNode(currentBlock()).txCount, 1);

        _pushStubs(1);
        EntityHashing.Op[] memory ops2 = new EntityHashing.Op[](1);
        ops2[0] = _op(EntityHashing.CREATE);
        this.execute(ops2);

        assertEq(getBlockNode(currentBlock()).txCount, 2);
    }

    function test_execute_sameBlock_secondTx_correctOpCounts() public {
        vm.roll(block.number + 10);
        BlockNumber current = currentBlock();

        // First tx — 2 ops.
        _pushStubs(2);
        EntityHashing.Op[] memory ops1 = new EntityHashing.Op[](2);
        ops1[0] = _op(EntityHashing.CREATE);
        ops1[1] = _op(EntityHashing.UPDATE);
        this.execute(ops1);

        // Second tx — 1 op.
        _pushStubs(1);
        EntityHashing.Op[] memory ops2 = new EntityHashing.Op[](1);
        ops2[0] = _op(EntityHashing.DELETE);
        this.execute(ops2);

        assertEq(txOpCount(current, 0), 2);
        assertEq(txOpCount(current, 1), 1);
    }

    function test_execute_sameBlock_hashChainContinuesAcrossTxs() public {
        vm.roll(block.number + 10);

        _pushStubs(1);
        EntityHashing.Op[] memory ops1 = new EntityHashing.Op[](1);
        ops1[0] = _op(EntityHashing.CREATE);
        this.execute(ops1);
        bytes32 hashAfterTx1 = changeSetHash();

        _pushStubs(1);
        bytes32 k1 = _stubKeys[0];
        bytes32 h1 = _stubHashes[0];
        EntityHashing.Op[] memory ops2 = new EntityHashing.Op[](1);
        ops2[0] = _op(EntityHashing.UPDATE);
        this.execute(ops2);

        bytes32 expected = EntityHashing.chainOp(hashAfterTx1, EntityHashing.UPDATE, k1, h1);
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
        EntityHashing.Op[] memory ops1 = new EntityHashing.Op[](1);
        ops1[0] = _op(EntityHashing.CREATE);
        this.execute(ops1);

        vm.roll(block.number + 5);
        BlockNumber blockB = currentBlock();
        _pushStubs(1);
        EntityHashing.Op[] memory ops2 = new EntityHashing.Op[](1);
        ops2[0] = _op(EntityHashing.CREATE);
        this.execute(ops2);

        // deployBlock → blockA → blockB
        EntityHashing.BlockNode memory deployNode = getBlockNode(deployBlock);
        assertEq(BlockNumber.unwrap(deployNode.nextBlock), BlockNumber.unwrap(blockA));

        EntityHashing.BlockNode memory nodeA = getBlockNode(blockA);
        assertEq(BlockNumber.unwrap(nodeA.prevBlock), BlockNumber.unwrap(deployBlock));
        assertEq(BlockNumber.unwrap(nodeA.nextBlock), BlockNumber.unwrap(blockB));

        EntityHashing.BlockNode memory nodeB = getBlockNode(blockB);
        assertEq(BlockNumber.unwrap(nodeB.prevBlock), BlockNumber.unwrap(blockA));
        assertEq(BlockNumber.unwrap(nodeB.nextBlock), 0);
    }

    function test_execute_crossBlock_headBlockUpdates() public {
        vm.roll(block.number + 10);
        BlockNumber blockA = currentBlock();
        _pushStubs(1);
        EntityHashing.Op[] memory ops1 = new EntityHashing.Op[](1);
        ops1[0] = _op(EntityHashing.CREATE);
        this.execute(ops1);
        assertEq(BlockNumber.unwrap(headBlock()), BlockNumber.unwrap(blockA));

        vm.roll(block.number + 5);
        BlockNumber blockB = currentBlock();
        _pushStubs(1);
        EntityHashing.Op[] memory ops2 = new EntityHashing.Op[](1);
        ops2[0] = _op(EntityHashing.CREATE);
        this.execute(ops2);
        assertEq(BlockNumber.unwrap(headBlock()), BlockNumber.unwrap(blockB));
    }

    function test_execute_crossBlock_hashChainContinues() public {
        _pushStubs(1);
        EntityHashing.Op[] memory ops1 = new EntityHashing.Op[](1);
        ops1[0] = _op(EntityHashing.CREATE);
        this.execute(ops1);
        bytes32 hashAfterBlock1 = changeSetHash();

        vm.roll(block.number + 1);
        _pushStubs(1);
        bytes32 k1 = _stubKeys[0];
        bytes32 h1 = _stubHashes[0];
        EntityHashing.Op[] memory ops2 = new EntityHashing.Op[](1);
        ops2[0] = _op(EntityHashing.UPDATE);
        this.execute(ops2);

        bytes32 expected = EntityHashing.chainOp(hashAfterBlock1, EntityHashing.UPDATE, k1, h1);
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

        EntityHashing.Op[] memory ops = new EntityHashing.Op[](3);
        ops[0] = _op(EntityHashing.CREATE);
        ops[1] = _op(EntityHashing.UPDATE);
        ops[2] = _op(EntityHashing.DELETE);
        this.execute(ops);

        bytes32 chain0 = EntityHashing.chainOp(bytes32(0), EntityHashing.CREATE, k0, h0);
        bytes32 chain1 = EntityHashing.chainOp(chain0, EntityHashing.UPDATE, k1, h1);
        bytes32 chain2 = EntityHashing.chainOp(chain1, EntityHashing.DELETE, k2, h2);

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
        EntityHashing.Op[] memory ops1 = new EntityHashing.Op[](2);
        ops1[0] = _op(EntityHashing.CREATE);
        ops1[1] = _op(EntityHashing.UPDATE);
        this.execute(ops1);

        // tx1: 1 op.
        _pushStubs(1);
        bytes32 tx1k0 = _stubKeys[0];
        bytes32 tx1h0 = _stubHashes[0];
        EntityHashing.Op[] memory ops2 = new EntityHashing.Op[](1);
        ops2[0] = _op(EntityHashing.DELETE);
        this.execute(ops2);

        bytes32 chain0 = EntityHashing.chainOp(bytes32(0), EntityHashing.CREATE, tx0k0, tx0h0);
        bytes32 chain1 = EntityHashing.chainOp(chain0, EntityHashing.UPDATE, tx0k1, tx0h1);
        assertEq(changeSetHashAtTx(current, 0), chain1);

        bytes32 chain2 = EntityHashing.chainOp(chain1, EntityHashing.DELETE, tx1k0, tx1h0);
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
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](1);
        ops[0] = _op(EntityHashing.CREATE);
        this.execute(ops);

        assertEq(BlockNumber.unwrap(headBlock()), BlockNumber.unwrap(deployBlock));
        assertEq(getBlockNode(deployBlock).txCount, 1);
    }

    // =========================================================================
    // Mixed op types in a single batch
    // =========================================================================

    function test_execute_allOpTypesInOneBatch() public {
        _pushStubs(6);

        EntityHashing.Op[] memory ops = new EntityHashing.Op[](6);
        ops[0] = _op(EntityHashing.CREATE);
        ops[1] = _op(EntityHashing.UPDATE);
        ops[2] = _op(EntityHashing.EXTEND);
        ops[3] = _op(EntityHashing.TRANSFER);
        ops[4] = _op(EntityHashing.DELETE);
        ops[5] = _op(EntityHashing.EXPIRE);
        this.execute(ops);

        assertEq(_stubIndex, 6);
        assertTrue(changeSetHash() != bytes32(0));
    }

    // =========================================================================
    // Invalid op in the middle of a batch reverts the whole tx
    // =========================================================================

    function test_execute_invalidOpMidBatch_reverts() public {
        _pushStubs(1);
        EntityHashing.Op[] memory ops = new EntityHashing.Op[](2);
        ops[0] = _op(EntityHashing.CREATE);
        ops[1] = _op(7);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.InvalidOpType.selector, uint8(7)));
        this.execute(ops);
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
