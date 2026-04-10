// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract TransferTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    BlockNumber expiresAt;
    bytes32 testKey;



    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doTransfer(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _transfer(op, currentBlock());
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

    function test_transfer_nonExistentEntity_reverts() public {
        bytes32 bogus = keccak256("bogus");
        EntityHashing.Op memory op = Lib.transferOp(bogus, bob);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, bogus));
        this.doTransfer(op);
    }

    // =========================================================================
    // Validation — expired entity
    // =========================================================================

    function test_transfer_expiredEntity_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt) + 1);

        EntityHashing.Op memory op = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doTransfer(op);
    }

    function test_transfer_atExpiryBlock_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        EntityHashing.Op memory op = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doTransfer(op);
    }

    // =========================================================================
    // Validation — not owner
    // =========================================================================

    function test_transfer_notOwner_reverts() public {
        EntityHashing.Op memory op = Lib.transferOp(testKey, charlie);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.NotOwner.selector, testKey, bob, alice));
        this.doTransfer(op);
    }

    // =========================================================================
    // Validation — zero address
    // =========================================================================

    function test_transfer_toZeroAddress_reverts() public {
        EntityHashing.Op memory op = Lib.transferOp(testKey, address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.TransferToZeroAddress.selector, testKey));
        this.doTransfer(op);
    }

    // =========================================================================
    // State — commitment updates
    // =========================================================================

    function test_transfer_updatesOwner() public {
        EntityHashing.Op memory op = Lib.transferOp(testKey, bob);

        vm.prank(alice);
        this.doTransfer(op);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        assertEq(c.owner, bob);
    }

    function test_transfer_updatesUpdatedAt() public {
        vm.roll(block.number + 10);

        EntityHashing.Op memory op = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        this.doTransfer(op);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        assertEq(BlockNumber.unwrap(c.updatedAt), uint32(block.number));
    }

    function test_transfer_preservesCoreHashCreatorExpiry() public {
        EntityHashing.Commitment memory before_ = getCommitment(testKey);

        EntityHashing.Op memory op = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        this.doTransfer(op);

        EntityHashing.Commitment memory after_ = getCommitment(testKey);
        assertEq(after_.coreHash, before_.coreHash);
        assertEq(after_.creator, before_.creator);
        assertEq(BlockNumber.unwrap(after_.createdAt), BlockNumber.unwrap(before_.createdAt));
        assertEq(BlockNumber.unwrap(after_.expiresAt), BlockNumber.unwrap(before_.expiresAt));
    }

    // =========================================================================
    // State — new owner can operate
    // =========================================================================

    function test_transfer_newOwnerCanTransferAgain() public {
        // alice → bob
        EntityHashing.Op memory op1 = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        this.doTransfer(op1);

        // bob → charlie
        EntityHashing.Op memory op2 = Lib.transferOp(testKey, charlie);
        vm.prank(bob);
        this.doTransfer(op2);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        assertEq(c.owner, charlie);
    }

    function test_transfer_previousOwnerCannotOperate() public {
        // alice → bob
        EntityHashing.Op memory op1 = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        this.doTransfer(op1);

        // alice tries again
        EntityHashing.Op memory op2 = Lib.transferOp(testKey, charlie);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.NotOwner.selector, testKey, alice, bob));
        this.doTransfer(op2);
    }

    // =========================================================================
    // State — returns correct key
    // =========================================================================

    function test_transfer_returnsEntityKey() public {
        EntityHashing.Op memory op = Lib.transferOp(testKey, bob);

        vm.prank(alice);
        (bytes32 returnedKey,) = this.doTransfer(op);

        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_transfer_entityHashUsesNewOwner() public {
        EntityHashing.Op memory op = Lib.transferOp(testKey, bob);

        vm.prank(alice);
        (, bytes32 entityHash_) = this.doTransfer(op);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        bytes32 expected = _wrapEntityHash(c.coreHash, bob, c.updatedAt, c.expiresAt);
        assertEq(entityHash_, expected);
    }

    function test_transfer_differentOwner_differentEntityHash() public {
        // Get hash with alice as owner.
        EntityHashing.Commitment memory beforeTransfer = getCommitment(testKey);
        bytes32 hashAlice =
            _wrapEntityHash(beforeTransfer.coreHash, alice, beforeTransfer.updatedAt, beforeTransfer.expiresAt);

        // Transfer to bob.
        EntityHashing.Op memory op = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        (, bytes32 hashBob) = this.doTransfer(op);

        assertNotEq(hashAlice, hashBob);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_transfer_emitsEntityTransferred() public {
        EntityHashing.Op memory op = Lib.transferOp(testKey, bob);

        vm.prank(alice);
        vm.expectEmit(true, true, true, false);
        emit EntityTransferred(testKey, alice, bob, bytes32(0));
        this.doTransfer(op);
    }
}
