// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber, currentBlock} from "../../../src/types/BlockNumber.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../src/Entity.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {encodeMime128} from "../../../src/types/Mime128.sol";

contract TransferTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doTransfer(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _transfer(op, currentBlock());
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory createOp = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // Validation — zero address
    // =========================================================================

    function test_transfer_toZeroAddress_reverts() public {
        Entity.Operation memory op = Lib.transferOp(testKey, address(0));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.TransferToZeroAddress.selector, testKey));
        this.doTransfer(op);
    }

    function test_transfer_toSelf_reverts() public {
        Entity.Operation memory op = Lib.transferOp(testKey, alice);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.TransferToSelf.selector, testKey));
        this.doTransfer(op);
    }

    // =========================================================================
    // State — commitment updates
    // =========================================================================

    function test_transfer_updatesOwner() public {
        Entity.Operation memory op = Lib.transferOp(testKey, bob);

        vm.prank(alice);
        this.doTransfer(op);

        Entity.Commitment memory c = commitment(testKey);
        assertEq(c.owner, bob);
    }

    function test_transfer_updatesUpdatedAt() public {
        vm.roll(block.number + 10);

        Entity.Operation memory op = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        this.doTransfer(op);

        Entity.Commitment memory c = commitment(testKey);
        assertEq(BlockNumber.unwrap(c.updatedAt), uint32(block.number));
    }

    function test_transfer_preservesCoreHashCreatorExpiry() public {
        Entity.Commitment memory before_ = commitment(testKey);

        Entity.Operation memory op = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        this.doTransfer(op);

        Entity.Commitment memory after_ = commitment(testKey);
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
        Entity.Operation memory op1 = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        this.doTransfer(op1);

        // bob → charlie
        Entity.Operation memory op2 = Lib.transferOp(testKey, charlie);
        vm.prank(bob);
        this.doTransfer(op2);

        Entity.Commitment memory c = commitment(testKey);
        assertEq(c.owner, charlie);
    }

    // =========================================================================
    // State — returns correct key
    // =========================================================================

    function test_transfer_returnsEntityKey() public {
        Entity.Operation memory op = Lib.transferOp(testKey, bob);

        vm.prank(alice);
        (bytes32 returnedKey,) = this.doTransfer(op);

        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_transfer_entityHashUsesNewOwner() public {
        Entity.Operation memory op = Lib.transferOp(testKey, bob);

        vm.prank(alice);
        (, bytes32 entityHash_) = this.doTransfer(op);

        Entity.Commitment memory c = commitment(testKey);
        bytes32 expected = _wrapEntityHash(c.coreHash, bob, c.updatedAt, c.expiresAt);
        assertEq(entityHash_, expected);
    }

    function test_transfer_differentOwner_differentEntityHash() public {
        // Get hash with alice as owner.
        Entity.Commitment memory beforeTransfer = commitment(testKey);
        bytes32 hashAlice =
            _wrapEntityHash(beforeTransfer.coreHash, alice, beforeTransfer.updatedAt, beforeTransfer.expiresAt);

        // Transfer to bob.
        Entity.Operation memory op = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        (, bytes32 hashBob) = this.doTransfer(op);

        assertNotEq(hashAlice, hashBob);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_transfer_emitsEntityOperation() public {
        Entity.Operation memory op = Lib.transferOp(testKey, bob);

        vm.prank(alice);
        vm.recordLogs();
        (, bytes32 entityHash_) = this.doTransfer(op);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EntityOperation.selector);
        assertEq(logs[0].topics[1], testKey);
        assertEq(logs[0].topics[2], bytes32(uint256(Entity.TRANSFER)));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(bob))));
        (BlockNumber emittedExpiry, bytes32 emittedHash) = abi.decode(logs[0].data, (BlockNumber, bytes32));
        assertEq(BlockNumber.unwrap(emittedExpiry), BlockNumber.unwrap(expiresAt));
        assertEq(emittedHash, entityHash_);
    }

    // =========================================================================
    // Guards — negative paths
    // =========================================================================

    function test_transfer_revertsIfNotFound() public {
        Entity.Operation memory op = Lib.transferOp(keccak256("bogus"), bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, keccak256("bogus")));
        this.doTransfer(op);
    }

    function test_transfer_revertsIfExpired() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        Entity.Operation memory op = Lib.transferOp(testKey, bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityExpired.selector, testKey, expiresAt));
        this.doTransfer(op);
    }

    function test_transfer_revertsIfNotOwner() public {
        Entity.Operation memory op = Lib.transferOp(testKey, bob);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Entity.NotOwner.selector, testKey, bob, alice));
        this.doTransfer(op);
    }
}
