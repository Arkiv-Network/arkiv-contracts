// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber} from "../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {Entity} from "../../src/Entity.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {encodeMime128} from "../../src/types/Mime128.sol";

/// @dev Tests that operations on deleted/expired entities revert correctly,
/// and that delete-after-create in the same block succeeds.
contract OperationSequencingTest is Test, EntityRegistry {
    address alice = makeAddr("alice");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doDelete(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _delete(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doExpire(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _expire(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doExtend(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _extend(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doUpdate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _update(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doTransfer(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _transfer(op, BlockNumber.wrap(uint32(block.number)));
    }

    function setUp() public {
        expiresAt = BlockNumber.wrap(uint32(block.number)) + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory createOp = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // Delete then operate — all should revert EntityNotFound
    // =========================================================================

    function test_deleteThenExtend_reverts() public {
        vm.prank(alice);
        this.doDelete(Lib.deleteOp(testKey));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, testKey));
        this.doExtend(Lib.extendOp(testKey, expiresAt + BlockNumber.wrap(500)));
    }

    function test_deleteThenUpdate_reverts() public {
        vm.prank(alice);
        this.doDelete(Lib.deleteOp(testKey));

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.updateOp(testKey, "new", encodeMime128("text/plain"), attrs);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, testKey));
        this.doUpdate(op);
    }

    function test_deleteThenTransfer_reverts() public {
        vm.prank(alice);
        this.doDelete(Lib.deleteOp(testKey));

        address bob = makeAddr("bob");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, testKey));
        this.doTransfer(Lib.transferOp(testKey, bob));
    }

    function test_deleteThenDelete_reverts() public {
        vm.prank(alice);
        this.doDelete(Lib.deleteOp(testKey));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, testKey));
        this.doDelete(Lib.deleteOp(testKey));
    }

    // =========================================================================
    // Expire then operate — all should revert EntityNotFound
    // =========================================================================

    function test_expireThenUpdate_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        this.doExpire(Lib.expireOp(testKey));

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.updateOp(testKey, "new", encodeMime128("text/plain"), attrs);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, testKey));
        this.doUpdate(op);
    }

    function test_expireThenExtend_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        this.doExpire(Lib.expireOp(testKey));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, testKey));
        this.doExtend(Lib.extendOp(testKey, expiresAt + BlockNumber.wrap(500)));
    }

    function test_expireThenExpire_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        this.doExpire(Lib.expireOp(testKey));

        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, testKey));
        this.doExpire(Lib.expireOp(testKey));
    }

    // =========================================================================
    // Delete in same block as create — should succeed
    // =========================================================================

    function test_deleteInSameBlockAsCreate_succeeds() public {
        // Create a fresh entity (same block as setUp's create).
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory createOp = Lib.createOp("ephemeral", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (bytes32 key,) = this.doCreate(createOp);

        // Delete it in the same block.
        vm.prank(alice);
        (bytes32 deletedKey,) = this.doDelete(Lib.deleteOp(key));
        assertEq(deletedKey, key);

        // Commitment is zeroed.
        Entity.Commitment memory c = commitment(key);
        assertEq(c.creator, address(0));
    }
}
