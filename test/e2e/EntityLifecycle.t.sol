// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber, currentBlock} from "../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {Entity} from "../../src/Entity.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {Mime128, encodeMime128} from "../../src/types/Mime128.sol";

/// @dev End-to-end tests that interact exclusively through the public
/// execute() entry point and public view functions. No stubs, no internal
/// access — exercises the full stack.
contract EntityLifecycleTest is Test {
    EntityRegistry registry;

    address alice;
    address bob;

    Mime128 textPlain;
    BlockNumber expiresAt;

    function setUp() public {
        registry = new EntityRegistry();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        textPlain = encodeMime128("text/plain");
        expiresAt = currentBlock() + BlockNumber.wrap(1000);
    }

    /// @dev Helper — build a single-op array and execute as sender.
    function _exec(address sender, Entity.Operation memory op) internal {
        Entity.Operation[] memory ops = new Entity.Operation[](1);
        ops[0] = op;
        vm.prank(sender);
        registry.execute(ops);
    }

    // =========================================================================
    // Full lifecycle: create → update → extend → transfer → delete
    // =========================================================================

    function test_fullLifecycle() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);

        // Create.
        _exec(alice, Lib.createOp("v1", textPlain, attrs, expiresAt));
        bytes32 key = registry.entityKey(alice, 0);

        Entity.Commitment memory c = registry.commitment(key);
        assertEq(c.creator, alice);
        assertEq(c.owner, alice);
        assertEq(registry.nonces(alice), 1);
        bytes32 hashAfterCreate = registry.changeSetHash();
        assertTrue(hashAfterCreate != bytes32(0));

        // Update.
        _exec(alice, Lib.updateOp(key, "v2", textPlain, attrs));
        Entity.Commitment memory c2 = registry.commitment(key);
        assertNotEq(c2.coreHash, c.coreHash);
        assertEq(c2.owner, alice);
        bytes32 hashAfterUpdate = registry.changeSetHash();
        assertNotEq(hashAfterUpdate, hashAfterCreate);

        // Extend.
        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        _exec(alice, Lib.extendOp(key, newExpiry));
        assertEq(BlockNumber.unwrap(registry.commitment(key).expiresAt), BlockNumber.unwrap(newExpiry));
        bytes32 hashAfterExtend = registry.changeSetHash();
        assertNotEq(hashAfterExtend, hashAfterUpdate);

        // Transfer to bob.
        _exec(alice, Lib.transferOp(key, bob));
        assertEq(registry.commitment(key).owner, bob);
        bytes32 hashAfterTransfer = registry.changeSetHash();
        assertNotEq(hashAfterTransfer, hashAfterExtend);

        // Delete by bob.
        _exec(bob, Lib.deleteOp(key));
        assertEq(registry.commitment(key).creator, address(0));
        bytes32 hashAfterDelete = registry.changeSetHash();
        assertNotEq(hashAfterDelete, hashAfterTransfer);
    }

    // =========================================================================
    // Multi-op batch — create + update in one execute call
    // =========================================================================

    function test_multiOpBatch() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);

        // We can't reference the key before it's created, but we can create
        // two entities in one batch.
        Entity.Operation[] memory ops = new Entity.Operation[](2);
        ops[0] = Lib.createOp("first", textPlain, attrs, expiresAt);
        ops[1] = Lib.createOp("second", textPlain, attrs, expiresAt);

        vm.prank(alice);
        registry.execute(ops);

        bytes32 key0 = registry.entityKey(alice, 0);
        bytes32 key1 = registry.entityKey(alice, 1);
        assertNotEq(key0, key1);

        assertEq(registry.commitment(key0).creator, alice);
        assertEq(registry.commitment(key1).creator, alice);
        assertEq(registry.nonces(alice), 2);

        // Both ops recorded in the same tx.
        BlockNumber current = currentBlock();
        assertEq(registry.txOpCount(current, 0), 2);

        // Per-op snapshots differ.
        bytes32 snap0 = registry.changeSetHashAtOp(current, 0, 0);
        bytes32 snap1 = registry.changeSetHashAtOp(current, 0, 1);
        assertTrue(snap0 != bytes32(0));
        assertTrue(snap1 != bytes32(0));
        assertNotEq(snap0, snap1);

        // Block-level hash equals last op.
        assertEq(registry.changeSetHash(), snap1);
    }

    // =========================================================================
    // Multi-block hash chain continuity
    // =========================================================================

    function test_multiBlock_hashChainContinues() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);

        // Block 1: create.
        _exec(alice, Lib.createOp("hello", textPlain, attrs, expiresAt));
        bytes32 key = registry.entityKey(alice, 0);
        BlockNumber block1 = currentBlock();
        bytes32 hashBlock1 = registry.changeSetHash();

        // Block 2: update.
        vm.roll(block.number + 5);
        _exec(alice, Lib.updateOp(key, "updated", textPlain, attrs));
        BlockNumber block2 = currentBlock();
        bytes32 hashBlock2 = registry.changeSetHash();

        // Chain advanced.
        assertNotEq(hashBlock2, hashBlock1);

        // Head moved.
        assertEq(BlockNumber.unwrap(registry.headBlock()), BlockNumber.unwrap(block2));

        // Linked list intact.
        Entity.BlockNode memory node1 = registry.getBlockNode(block1);
        assertEq(BlockNumber.unwrap(node1.nextBlock), BlockNumber.unwrap(block2));

        Entity.BlockNode memory node2 = registry.getBlockNode(block2);
        assertEq(BlockNumber.unwrap(node2.prevBlock), BlockNumber.unwrap(block1));

        // Historical hash still accessible.
        assertEq(registry.changeSetHashAtBlock(block1), hashBlock1);
    }

    // =========================================================================
    // Expire lifecycle through execute
    // =========================================================================

    function test_expireLifecycleThroughExecute() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);

        // Create.
        _exec(alice, Lib.createOp("ephemeral", textPlain, attrs, expiresAt));
        bytes32 key = registry.entityKey(alice, 0);
        assertTrue(registry.commitment(key).creator != address(0));

        // Roll to expiry.
        vm.roll(BlockNumber.unwrap(expiresAt));

        // Anyone can expire through execute.
        _exec(bob, Lib.expireOp(key));
        assertEq(registry.commitment(key).creator, address(0));
    }

    // =========================================================================
    // Multiple entities by different owners
    // =========================================================================

    function test_multipleOwners_independentEntities() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);

        _exec(alice, Lib.createOp("alice-doc", textPlain, attrs, expiresAt));
        _exec(bob, Lib.createOp("bob-doc", textPlain, attrs, expiresAt));

        bytes32 aliceKey = registry.entityKey(alice, 0);
        bytes32 bobKey = registry.entityKey(bob, 0);
        assertNotEq(aliceKey, bobKey);

        // Each owner can only operate on their own entity.
        assertEq(registry.commitment(aliceKey).owner, alice);
        assertEq(registry.commitment(bobKey).owner, bob);

        // Nonces are independent.
        assertEq(registry.nonces(alice), 1);
        assertEq(registry.nonces(bob), 1);
    }

    // =========================================================================
    // Genesis state
    // =========================================================================

    function test_initialState() public view {
        assertEq(registry.changeSetHash(), bytes32(0));
        assertEq(BlockNumber.unwrap(registry.genesisBlock()), BlockNumber.unwrap(registry.headBlock()));
        assertEq(registry.nonces(alice), 0);
    }
}
