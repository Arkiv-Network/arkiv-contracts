// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber} from "../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {Entity} from "../../src/Entity.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {encodeMime128} from "../../src/types/Mime128.sol";

/// @dev Tests ownership transfer chains and that only the current owner
/// can perform owner-gated operations.
contract OwnershipLifecycleTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doTransfer(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _transfer(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doUpdate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _update(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doDelete(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _delete(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doExtend(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _extend(op, BlockNumber.wrap(uint32(block.number)));
    }

    function setUp() public {
        expiresAt = BlockNumber.wrap(uint32(block.number)) + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory createOp = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // Transfer chain — alice → bob → charlie
    // =========================================================================

    function test_transferChain_ownerUpdatesCorrectly() public {
        // alice → bob
        vm.prank(alice);
        this.doTransfer(Lib.transferOp(testKey, bob));
        assertEq(commitment(testKey).owner, bob);

        // bob → charlie
        vm.prank(bob);
        this.doTransfer(Lib.transferOp(testKey, charlie));
        assertEq(commitment(testKey).owner, charlie);
    }

    // =========================================================================
    // Previous owner locked out after transfer
    // =========================================================================

    function test_previousOwnerCannotUpdate() public {
        vm.prank(alice);
        this.doTransfer(Lib.transferOp(testKey, bob));

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.updateOp(testKey, "new", encodeMime128("text/plain"), attrs);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.NotOwner.selector, testKey, alice, bob));
        this.doUpdate(op);
    }

    function test_previousOwnerCannotExtend() public {
        vm.prank(alice);
        this.doTransfer(Lib.transferOp(testKey, bob));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.NotOwner.selector, testKey, alice, bob));
        this.doExtend(Lib.extendOp(testKey, expiresAt + BlockNumber.wrap(500)));
    }

    function test_previousOwnerCannotDelete() public {
        vm.prank(alice);
        this.doTransfer(Lib.transferOp(testKey, bob));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.NotOwner.selector, testKey, alice, bob));
        this.doDelete(Lib.deleteOp(testKey));
    }

    function test_previousOwnerCannotTransfer() public {
        vm.prank(alice);
        this.doTransfer(Lib.transferOp(testKey, bob));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.NotOwner.selector, testKey, alice, bob));
        this.doTransfer(Lib.transferOp(testKey, charlie));
    }

    // =========================================================================
    // New owner can operate
    // =========================================================================

    function test_newOwnerCanUpdate() public {
        vm.prank(alice);
        this.doTransfer(Lib.transferOp(testKey, bob));

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.updateOp(testKey, "updated by bob", encodeMime128("text/plain"), attrs);
        vm.prank(bob);
        (bytes32 key,) = this.doUpdate(op);
        assertEq(key, testKey);
    }

    function test_newOwnerCanExtend() public {
        vm.prank(alice);
        this.doTransfer(Lib.transferOp(testKey, bob));

        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        vm.prank(bob);
        this.doExtend(Lib.extendOp(testKey, newExpiry));
        assertEq(BlockNumber.unwrap(commitment(testKey).expiresAt), BlockNumber.unwrap(newExpiry));
    }

    function test_newOwnerCanDelete() public {
        vm.prank(alice);
        this.doTransfer(Lib.transferOp(testKey, bob));

        vm.prank(bob);
        this.doDelete(Lib.deleteOp(testKey));
        assertEq(commitment(testKey).creator, address(0));
    }
}
