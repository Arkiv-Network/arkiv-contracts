// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../src/Entity.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {encodeMime128} from "../../../src/types/Mime128.sol";

contract DeleteTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doDelete(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _delete(op, currentBlock());
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory createOp = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // State — commitment removed
    // =========================================================================

    function test_delete_removesCommitment() public {
        Entity.Operation memory op = Lib.deleteOp(testKey);

        vm.prank(alice);
        this.doDelete(op);

        Entity.Commitment memory c = commitment(testKey);
        assertEq(c.creator, address(0));
        assertEq(c.owner, address(0));
        assertEq(c.coreHash, bytes32(0));
        assertEq(BlockNumber.unwrap(c.createdAt), 0);
        assertEq(BlockNumber.unwrap(c.updatedAt), 0);
        assertEq(BlockNumber.unwrap(c.expiresAt), 0);
    }

    // =========================================================================
    // State — returns correct key
    // =========================================================================

    function test_delete_returnsEntityKey() public {
        Entity.Operation memory op = Lib.deleteOp(testKey);

        vm.prank(alice);
        (bytes32 returnedKey,) = this.doDelete(op);

        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_delete_returnsSnapshotHash() public {
        Entity.Commitment memory c = commitment(testKey);
        bytes32 expected = _wrapEntityHash(c.coreHash, c.owner, c.updatedAt, c.expiresAt);

        Entity.Operation memory op = Lib.deleteOp(testKey);
        vm.prank(alice);
        (, bytes32 entityHash_) = this.doDelete(op);

        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_delete_emitsEntityOp() public {
        Entity.Operation memory op = Lib.deleteOp(testKey);

        vm.prank(alice);
        vm.recordLogs();
        (, bytes32 entityHash_) = this.doDelete(op);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EntityOp.selector);
        assertEq(logs[0].topics[1], testKey);
        assertEq(logs[0].topics[2], bytes32(uint256(Entity.DELETE)));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(alice))));
        (BlockNumber emittedExpiry, bytes32 emittedHash) = abi.decode(logs[0].data, (BlockNumber, bytes32));
        assertEq(BlockNumber.unwrap(emittedExpiry), BlockNumber.unwrap(expiresAt));
        assertEq(emittedHash, entityHash_);
    }

    // =========================================================================
    // Guards — negative paths
    // =========================================================================

    function test_delete_revertsIfNotFound() public {
        Entity.Operation memory op = Lib.deleteOp(keccak256("bogus"));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, keccak256("bogus")));
        this.doDelete(op);
    }

    function test_delete_revertsIfExpired() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        Entity.Operation memory op = Lib.deleteOp(testKey);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityExpired.selector, testKey, expiresAt));
        this.doDelete(op);
    }

    function test_delete_revertsIfNotOwner() public {
        Entity.Operation memory op = Lib.deleteOp(testKey);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Entity.NotOwner.selector, testKey, bob, alice));
        this.doDelete(op);
    }
}
