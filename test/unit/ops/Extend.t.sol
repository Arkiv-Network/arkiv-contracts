// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {encodeMime128} from "../../../src/types/Mime128.sol";

contract ExtendTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doExtend(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _extend(op, currentBlock());
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory createOp = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // Validation — expiry not extended
    // =========================================================================

    function test_extend_sameExpiry_reverts() public {
        EntityHashing.Op memory op = Lib.extendOp(testKey, expiresAt);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.ExpiryNotExtended.selector, testKey, expiresAt, expiresAt));
        this.doExtend(op);
    }

    function test_extend_lowerExpiry_reverts() public {
        BlockNumber lower = expiresAt - BlockNumber.wrap(100);
        EntityHashing.Op memory op = Lib.extendOp(testKey, lower);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.ExpiryNotExtended.selector, testKey, lower, expiresAt));
        this.doExtend(op);
    }

    // =========================================================================
    // State — commitment updates
    // =========================================================================

    function test_extend_updatesExpiresAt() public {
        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(testKey, newExpiry);

        vm.prank(alice);
        this.doExtend(op);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        assertEq(BlockNumber.unwrap(c.expiresAt), BlockNumber.unwrap(newExpiry));
    }

    function test_extend_updatesUpdatedAt() public {
        vm.roll(block.number + 10);

        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(testKey, newExpiry);

        vm.prank(alice);
        this.doExtend(op);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        assertEq(BlockNumber.unwrap(c.updatedAt), uint32(block.number));
    }

    function test_extend_preservesCoreHashAndOwner() public {
        EntityHashing.Commitment memory before_ = getCommitment(testKey);

        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(testKey, newExpiry);

        vm.prank(alice);
        this.doExtend(op);

        EntityHashing.Commitment memory after_ = getCommitment(testKey);
        assertEq(after_.coreHash, before_.coreHash);
        assertEq(after_.creator, before_.creator);
        assertEq(after_.owner, before_.owner);
        assertEq(BlockNumber.unwrap(after_.createdAt), BlockNumber.unwrap(before_.createdAt));
    }

    // =========================================================================
    // State — returns correct key
    // =========================================================================

    function test_extend_returnsEntityKey() public {
        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(testKey, newExpiry);

        vm.prank(alice);
        (bytes32 returnedKey,) = this.doExtend(op);

        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_extend_entityHashUsesNewExpiry() public {
        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(testKey, newExpiry);

        vm.prank(alice);
        (, bytes32 entityHash_) = this.doExtend(op);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        bytes32 expected = _wrapEntityHash(c.coreHash, c.owner, c.updatedAt, newExpiry);
        assertEq(entityHash_, expected);
    }

    function test_extend_differentExpiry_differentEntityHash() public {
        BlockNumber expiry1 = expiresAt + BlockNumber.wrap(100);
        BlockNumber expiry2 = expiresAt + BlockNumber.wrap(200);

        EntityHashing.Op memory op1 = Lib.extendOp(testKey, expiry1);
        vm.prank(alice);
        (, bytes32 hash1) = this.doExtend(op1);

        EntityHashing.Op memory op2 = Lib.extendOp(testKey, expiry2);
        vm.prank(alice);
        (, bytes32 hash2) = this.doExtend(op2);

        assertNotEq(hash1, hash2);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_extend_emitsEntityOp() public {
        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(testKey, newExpiry);

        vm.prank(alice);
        vm.recordLogs();
        (, bytes32 entityHash_) = this.doExtend(op);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EntityOp.selector);
        assertEq(logs[0].topics[1], testKey);
        assertEq(logs[0].topics[2], bytes32(uint256(EntityHashing.EXTEND)));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(alice))));
        (BlockNumber emittedExpiry, bytes32 emittedHash) = abi.decode(logs[0].data, (BlockNumber, bytes32));
        assertEq(BlockNumber.unwrap(emittedExpiry), BlockNumber.unwrap(newExpiry));
        assertEq(emittedHash, entityHash_);
    }

    // =========================================================================
    // Guards — negative paths
    // =========================================================================

    function test_extend_revertsIfNotFound() public {
        EntityHashing.Op memory op = Lib.extendOp(keccak256("bogus"), expiresAt + BlockNumber.wrap(500));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, keccak256("bogus")));
        this.doExtend(op);
    }

    function test_extend_revertsIfExpired() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        EntityHashing.Op memory op = Lib.extendOp(testKey, expiresAt + BlockNumber.wrap(500));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doExtend(op);
    }

    function test_extend_revertsIfNotOwner() public {
        EntityHashing.Op memory op = Lib.extendOp(testKey, expiresAt + BlockNumber.wrap(500));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.NotOwner.selector, testKey, bob, alice));
        this.doExtend(op);
    }
}
