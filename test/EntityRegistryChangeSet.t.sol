// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BlockNumber} from "../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {EntityRegistry} from "../src/EntityRegistry.sol";
import {EntityRegistryBase, EntityRegistryTestable} from "./EntityRegistryBase.t.sol";

contract EntityRegistryChangeSetTest is EntityRegistryBase {
    BlockNumber expiresAt = BlockNumber.wrap(1000);

    function _singleCreate(address sender, bytes memory payload) internal {
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);
        EntityRegistry.Op[] memory ops = new EntityRegistry.Op[](1);
        ops[0] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: payload,
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: expiresAt
        });
        vm.prank(sender);
        registry.execute(ops);
    }

    // -------------------------------------------------------------------------
    // Initial state
    // -------------------------------------------------------------------------

    function test_initialState_zero() public view {
        assertEq(registry.changeSetHash(), bytes32(0));
    }

    // -------------------------------------------------------------------------
    // Single mutation
    // -------------------------------------------------------------------------

    function test_singleOp_producesNonZeroHash() public {
        _singleCreate(alice, "hello");
        assertNotEq(registry.changeSetHash(), bytes32(0));
    }

    // -------------------------------------------------------------------------
    // Chaining — multiple ops
    // -------------------------------------------------------------------------

    function test_multipleOps_hashChangesEachTime() public {
        _singleCreate(alice, "first");
        bytes32 hash1 = registry.changeSetHash();

        _singleCreate(alice, "second");
        bytes32 hash2 = registry.changeSetHash();

        assertNotEq(hash1, hash2);
    }

    // -------------------------------------------------------------------------
    // Batch accumulation — single SSTORE
    // -------------------------------------------------------------------------

    function test_batch_hashesAllOpsInOneTx() public {
        // GIVEN two creates in a single batch
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);
        EntityRegistry.Op[] memory ops = new EntityRegistry.Op[](2);
        ops[0] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: "first",
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: expiresAt
        });
        ops[1] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: "second",
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: expiresAt
        });

        vm.prank(alice);
        registry.execute(ops);

        // THEN hash is non-zero and includes both ops
        bytes32 batchHash = registry.changeSetHash();
        assertNotEq(batchHash, bytes32(0));

        // AND it differs from a single-op hash (both ops contributed)
        EntityRegistryTestable registrySingle = new EntityRegistryTestable();
        EntityRegistry.Op[] memory singleOps = new EntityRegistry.Op[](1);
        singleOps[0] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: "first",
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: expiresAt
        });
        vm.prank(alice);
        registrySingle.execute(singleOps);

        assertNotEq(batchHash, registrySingle.changeSetHash());
    }

    // -------------------------------------------------------------------------
    // Cross-block continuity
    // -------------------------------------------------------------------------

    function test_crossBlock_chainsWithoutReset() public {
        _singleCreate(alice, "block1");
        bytes32 hash1 = registry.changeSetHash();

        vm.roll(block.number + 1);
        _singleCreate(alice, "block2");
        bytes32 hash2 = registry.changeSetHash();

        assertNotEq(hash1, hash2);
    }

    // -------------------------------------------------------------------------
    // Ordering matters
    // -------------------------------------------------------------------------

    function test_orderMatters() public {
        EntityRegistryTestable r1 = new EntityRegistryTestable();
        EntityRegistryTestable r2 = new EntityRegistryTestable();

        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);
        EntityRegistry.Op[] memory ops = new EntityRegistry.Op[](2);

        // r1: A then B
        ops[0] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: "A",
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: expiresAt
        });
        ops[1] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: "B",
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: expiresAt
        });
        vm.prank(alice);
        r1.execute(ops);

        // r2: B then A
        ops[0] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: "B",
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: expiresAt
        });
        ops[1] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: "A",
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: expiresAt
        });
        vm.prank(alice);
        r2.execute(ops);

        assertNotEq(r1.changeSetHash(), r2.changeSetHash());
    }

    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_differentPayload_differentHash() public {
        EntityRegistryTestable r1 = new EntityRegistryTestable();
        EntityRegistryTestable r2 = new EntityRegistryTestable();

        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);
        EntityRegistry.Op[] memory ops = new EntityRegistry.Op[](1);

        ops[0] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: "payload_a",
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: expiresAt
        });
        vm.prank(alice);
        r1.execute(ops);

        ops[0] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: "payload_b",
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: expiresAt
        });
        vm.prank(alice);
        r2.execute(ops);

        assertNotEq(r1.changeSetHash(), r2.changeSetHash());
    }

    // -------------------------------------------------------------------------
    // expireEntities accumulates correctly
    // -------------------------------------------------------------------------

    function test_expireEntities_accumulatesHash() public {
        // Create two entities
        _singleCreate(alice, "e1");
        _singleCreate(alice, "e2");
        bytes32 hashBefore = registry.changeSetHash();

        // Expire both
        vm.roll(1000);
        bytes32 key0 = registry.entityKey(alice, 0);
        bytes32 key1 = registry.entityKey(alice, 1);
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = key0;
        keys[1] = key1;
        registry.expireEntities(keys);

        // Hash changed
        assertNotEq(registry.changeSetHash(), hashBefore);
    }
}
