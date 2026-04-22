// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber} from "../../../contracts/types/BlockNumber.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../contracts/Entity.sol";
import {EntityRegistry} from "../../../contracts/EntityRegistry.sol";
import {encodeMime128} from "../../../contracts/types/Mime128.sol";

contract ExpireTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doExpire(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _expire(op, BlockNumber.wrap(uint32(block.number)));
    }

    function setUp() public {
        expiresAt = BlockNumber.wrap(uint32(block.number)) + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory createOp = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // State — commitment removed
    // =========================================================================

    function test_expire_removesCommitment() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        this.doExpire(Lib.expireOp(testKey));

        Entity.Commitment memory c = commitment(testKey);
        assertEq(c.creator, address(0));
        assertEq(c.owner, address(0));
        assertEq(c.coreHash, bytes32(0));
        assertEq(BlockNumber.unwrap(c.createdAt), 0);
        assertEq(BlockNumber.unwrap(c.updatedAt), 0);
        assertEq(BlockNumber.unwrap(c.expiresAt), 0);
    }

    // =========================================================================
    // Return values
    // =========================================================================

    function test_expire_returnsEntityKey() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        (bytes32 returnedKey,) = this.doExpire(Lib.expireOp(testKey));
        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_expire_returnsSnapshotHash() public {
        Entity.Commitment memory c = commitment(testKey);
        bytes32 expected = _wrapEntityHash(c.coreHash, c.owner, c.updatedAt, c.expiresAt);

        vm.roll(BlockNumber.unwrap(expiresAt));
        (, bytes32 entityHash_) = this.doExpire(Lib.expireOp(testKey));
        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_expire_emitsEntityOperation() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        vm.recordLogs();
        (, bytes32 entityHash_) = this.doExpire(Lib.expireOp(testKey));

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EntityOperation.selector);
        assertEq(logs[0].topics[1], testKey);
        assertEq(logs[0].topics[2], bytes32(uint256(Entity.EXPIRE)));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(alice))));
        (BlockNumber emittedExpiry, bytes32 emittedHash) = abi.decode(logs[0].data, (BlockNumber, bytes32));
        assertEq(BlockNumber.unwrap(emittedExpiry), BlockNumber.unwrap(expiresAt));
        assertEq(emittedHash, entityHash_);
    }

    // =========================================================================
    // Guards — negative paths
    // =========================================================================

    function test_expire_revertsIfNotFound() public {
        bytes32 bogus = keccak256("bogus");
        vm.roll(BlockNumber.unwrap(expiresAt));
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, bogus));
        this.doExpire(Lib.expireOp(bogus));
    }

    function test_expire_revertsIfNotExpired() public {
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotExpired.selector, testKey, expiresAt));
        this.doExpire(Lib.expireOp(testKey));
    }
}
