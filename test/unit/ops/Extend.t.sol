// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

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
        EntityHashing.Op memory createOp = Lib.createOp("hello", "text/plain", attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // Validation — entity not found
    // =========================================================================

    function test_extend_nonExistentEntity_reverts() public {
        bytes32 bogus = keccak256("bogus");
        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(bogus, newExpiry);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, bogus));
        this.doExtend(op);
    }

    // =========================================================================
    // Validation — expired entity
    // =========================================================================

    function test_extend_expiredEntity_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt) + 1);

        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(testKey, newExpiry);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doExtend(op);
    }

    function test_extend_atExpiryBlock_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(testKey, newExpiry);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doExtend(op);
    }

    // =========================================================================
    // Validation — not owner
    // =========================================================================

    function test_extend_notOwner_reverts() public {
        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(testKey, newExpiry);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.NotOwner.selector, testKey, bob, alice));
        this.doExtend(op);
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

    function test_extend_emitsEntityExtended() public {
        BlockNumber newExpiry = expiresAt + BlockNumber.wrap(500);
        EntityHashing.Op memory op = Lib.extendOp(testKey, newExpiry);

        vm.prank(alice);
        vm.expectEmit(true, true, true, false);
        emit EntityExtended(testKey, alice, newExpiry, bytes32(0));
        this.doExtend(op);
    }
}
