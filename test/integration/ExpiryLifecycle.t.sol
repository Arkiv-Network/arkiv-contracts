// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber} from "../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {Entity} from "../../src/Entity.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {encodeMime128} from "../../src/types/Mime128.sol";

/// @dev Tests the full expiry lifecycle: extend multiple times, operations
/// fail once expired, anyone can call expire, entity is removed.
contract ExpiryLifecycleTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doExtend(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _extend(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doExpire(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _expire(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doUpdate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _update(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doDelete(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _delete(op, BlockNumber.wrap(uint32(block.number)));
    }

    function setUp() public {
        expiresAt = BlockNumber.wrap(uint32(block.number)) + BlockNumber.wrap(100);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory createOp = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // Extend multiple times
    // =========================================================================

    function test_extendMultipleTimes() public {
        BlockNumber expiry1 = expiresAt + BlockNumber.wrap(100);
        vm.prank(alice);
        this.doExtend(Lib.extendOp(testKey, expiry1));
        assertEq(BlockNumber.unwrap(commitment(testKey).expiresAt), BlockNumber.unwrap(expiry1));

        BlockNumber expiry2 = expiry1 + BlockNumber.wrap(100);
        vm.prank(alice);
        this.doExtend(Lib.extendOp(testKey, expiry2));
        assertEq(BlockNumber.unwrap(commitment(testKey).expiresAt), BlockNumber.unwrap(expiry2));
    }

    // =========================================================================
    // Operations fail once expired
    // =========================================================================

    function test_expiredEntityCannotBeUpdated() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.updateOp(testKey, "new", encodeMime128("text/plain"), attrs);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityExpired.selector, testKey, expiresAt));
        this.doUpdate(op);
    }

    function test_expiredEntityCannotBeExtended() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityExpired.selector, testKey, expiresAt));
        this.doExtend(Lib.extendOp(testKey, expiresAt + BlockNumber.wrap(500)));
    }

    function test_expiredEntityCannotBeDeleted() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityExpired.selector, testKey, expiresAt));
        this.doDelete(Lib.deleteOp(testKey));
    }

    // =========================================================================
    // Anyone can expire
    // =========================================================================

    function test_nonOwnerCanExpire() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        vm.prank(bob);
        this.doExpire(Lib.expireOp(testKey));
        assertEq(commitment(testKey).creator, address(0));
    }

    // =========================================================================
    // Extend rescues entity from expiry
    // =========================================================================

    function test_extendThenOperateAfterOriginalExpiry() public {
        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        vm.prank(alice);
        this.doExtend(Lib.extendOp(testKey, newExpiry));

        // Roll past original expiry but before new expiry.
        vm.roll(BlockNumber.unwrap(expiresAt) + 1);

        // Update should succeed — entity is still active.
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.updateOp(testKey, "still alive", encodeMime128("text/plain"), attrs);
        vm.prank(alice);
        (bytes32 key,) = this.doUpdate(op);
        assertEq(key, testKey);
    }

    // =========================================================================
    // Full lifecycle: create → extend → expire → gone
    // =========================================================================

    function test_fullExpiryLifecycle() public {
        // Extend.
        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(200);
        vm.prank(alice);
        this.doExtend(Lib.extendOp(testKey, newExpiry));

        // Roll to new expiry.
        vm.roll(BlockNumber.unwrap(newExpiry));

        // Expire (by non-owner).
        vm.prank(bob);
        this.doExpire(Lib.expireOp(testKey));

        // Entity is gone.
        Entity.Commitment memory c = commitment(testKey);
        assertEq(c.creator, address(0));
        assertEq(c.owner, address(0));
        assertEq(c.coreHash, bytes32(0));
    }
}
