// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract DeleteTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    function _validateAttributes(EntityHashing.Attribute[] calldata) internal pure override {}

    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doDelete(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _delete(op, currentBlock());
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory createOp = Lib.createOp("hello", "text/plain", attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // Validation — entity not found
    // =========================================================================

    function test_delete_nonExistentEntity_reverts() public {
        bytes32 bogus = keccak256("bogus");
        EntityHashing.Op memory op = Lib.deleteOp(bogus);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, bogus));
        this.doDelete(op);
    }

    // =========================================================================
    // Validation — expired entity
    // =========================================================================

    function test_delete_expiredEntity_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt) + 1);

        EntityHashing.Op memory op = Lib.deleteOp(testKey);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doDelete(op);
    }

    function test_delete_atExpiryBlock_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        EntityHashing.Op memory op = Lib.deleteOp(testKey);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doDelete(op);
    }

    // =========================================================================
    // Validation — not owner
    // =========================================================================

    function test_delete_notOwner_reverts() public {
        EntityHashing.Op memory op = Lib.deleteOp(testKey);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.NotOwner.selector, testKey, bob, alice));
        this.doDelete(op);
    }

    // =========================================================================
    // State — commitment removed
    // =========================================================================

    function test_delete_removesCommitment() public {
        EntityHashing.Op memory op = Lib.deleteOp(testKey);

        vm.prank(alice);
        this.doDelete(op);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        assertEq(c.creator, address(0));
        assertEq(c.owner, address(0));
        assertEq(c.coreHash, bytes32(0));
        assertEq(BlockNumber.unwrap(c.createdAt), 0);
        assertEq(BlockNumber.unwrap(c.updatedAt), 0);
        assertEq(BlockNumber.unwrap(c.expiresAt), 0);
    }

    function test_delete_entityNotFoundAfterDelete() public {
        EntityHashing.Op memory op = Lib.deleteOp(testKey);

        vm.prank(alice);
        this.doDelete(op);

        // Trying to delete again should fail with EntityNotFound.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, testKey));
        this.doDelete(op);
    }

    // =========================================================================
    // State — returns correct key
    // =========================================================================

    function test_delete_returnsEntityKey() public {
        EntityHashing.Op memory op = Lib.deleteOp(testKey);

        vm.prank(alice);
        (bytes32 returnedKey,) = this.doDelete(op);

        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_delete_returnsSnapshotHash() public {
        // Compute expected hash from commitment before deletion.
        EntityHashing.Commitment memory c = getCommitment(testKey);
        bytes32 expected = _entityHash(c.coreHash, c.owner, c.updatedAt, c.expiresAt);

        EntityHashing.Op memory op = Lib.deleteOp(testKey);
        vm.prank(alice);
        (, bytes32 entityHash_) = this.doDelete(op);

        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_delete_emitsEntityDeleted() public {
        EntityHashing.Op memory op = Lib.deleteOp(testKey);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit EntityDeleted(testKey, alice, bytes32(0));
        this.doDelete(op);
    }
}
