// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber, currentBlock} from "../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {Entity} from "../../src/Entity.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {encodeMime128} from "../../src/types/Mime128.sol";

/// @dev Exercises every public view function via external calls so that
/// forge coverage counts them, and verifies correctness of returned values.
contract ViewsTest is Test {
    EntityRegistry registry;

    address alice = makeAddr("alice");
    bytes32 testKey;
    BlockNumber deployBlock;
    BlockNumber expiresAt;

    function setUp() public {
        registry = new EntityRegistry();
        deployBlock = registry.genesisBlock();
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation[] memory ops = new Entity.Operation[](1);
        ops[0] = Entity.Operation({
            operationType: Entity.CREATE,
            entityKey: bytes32(0),
            payload: "hello",
            contentType: encodeMime128("text/plain"),
            attributes: attrs,
            expiresAt: expiresAt,
            newOwner: address(0)
        });

        vm.prank(alice);
        registry.execute(ops);

        testKey = registry.entityKey(alice, 0);
    }

    // =========================================================================
    // Changeset hash views — single op means all four levels agree
    // =========================================================================

    function test_changeSetHash() public view {
        bytes32 hash = registry.changeSetHash();
        assertTrue(hash != bytes32(0));
        // Head block, block-level, tx-level, and op-level should all match.
        assertEq(hash, registry.changeSetHashAtBlock(deployBlock));
        assertEq(hash, registry.changeSetHashAtTx(deployBlock, 0));
        assertEq(hash, registry.changeSetHashAtOp(deployBlock, 0, 0));
    }

    function test_changeSetHashAtBlock_uninitializedReturnsZero() public view {
        assertEq(registry.changeSetHashAtBlock(BlockNumber.wrap(999999)), bytes32(0));
    }

    function test_changeSetHashAtTx_uninitializedReturnsZero() public view {
        assertEq(registry.changeSetHashAtTx(BlockNumber.wrap(999999), 0), bytes32(0));
    }

    function test_changeSetHashAtOp_uninitializedReturnsZero() public view {
        assertEq(registry.changeSetHashAtOp(BlockNumber.wrap(999999), 0, 0), bytes32(0));
    }

    // =========================================================================
    // entityKey
    // =========================================================================

    function test_entityKey() public view {
        bytes32 key = registry.entityKey(alice, 0);
        assertEq(key, testKey);
        // Different nonce produces different key.
        assertTrue(registry.entityKey(alice, 1) != testKey);
    }

    // =========================================================================
    // Block pointers
    // =========================================================================

    function test_genesisBlock() public view {
        assertEq(BlockNumber.unwrap(registry.genesisBlock()), BlockNumber.unwrap(deployBlock));
    }

    function test_headBlock() public view {
        assertEq(BlockNumber.unwrap(registry.headBlock()), BlockNumber.unwrap(deployBlock));
    }

    function test_getBlockNode() public view {
        Entity.BlockNode memory node = registry.getBlockNode(deployBlock);
        assertEq(node.txCount, 1);
        // Deploy block is both genesis and head — no neighbours.
        assertEq(BlockNumber.unwrap(node.prevBlock), 0);
        assertEq(BlockNumber.unwrap(node.nextBlock), 0);
    }

    function test_getBlockNode_uninitializedReturnsZero() public view {
        Entity.BlockNode memory node = registry.getBlockNode(BlockNumber.wrap(999999));
        assertEq(node.txCount, 0);
        assertEq(BlockNumber.unwrap(node.prevBlock), 0);
        assertEq(BlockNumber.unwrap(node.nextBlock), 0);
    }

    // =========================================================================
    // txOpCount
    // =========================================================================

    function test_txOpCount() public view {
        assertEq(registry.txOpCount(deployBlock, 0), 1);
    }

    function test_txOpCount_uninitializedReturnsZero() public view {
        assertEq(registry.txOpCount(BlockNumber.wrap(999999), 0), 0);
    }

    // =========================================================================
    // commitment
    // =========================================================================

    function test_commitment() public view {
        Entity.Commitment memory c = registry.commitment(testKey);
        assertEq(c.owner, alice);
        assertEq(c.creator, alice);
        assertEq(BlockNumber.unwrap(c.createdAt), BlockNumber.unwrap(deployBlock));
        assertEq(BlockNumber.unwrap(c.updatedAt), BlockNumber.unwrap(deployBlock));
        assertEq(BlockNumber.unwrap(c.expiresAt), BlockNumber.unwrap(expiresAt));
        assertTrue(c.coreHash != bytes32(0));
    }

    function test_commitment_uninitializedReturnsZero() public view {
        Entity.Commitment memory c = registry.commitment(keccak256("nonexistent"));
        assertEq(c.creator, address(0));
        assertEq(c.owner, address(0));
        assertEq(c.coreHash, bytes32(0));
    }

    // =========================================================================
    // nonces
    // =========================================================================

    function test_nonces() public view {
        assertEq(registry.nonces(alice), 1);
        assertEq(registry.nonces(address(0)), 0);
    }
}
