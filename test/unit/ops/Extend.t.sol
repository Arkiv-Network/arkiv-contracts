// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber32} from "../../../contracts/types/BlockNumber32.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../contracts/Entity.sol";
import {EntityRegistry} from "../../../contracts/EntityRegistry.sol";
import {encodeMime128} from "../../../contracts/types/Mime128.sol";

contract ExtendTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber32 btl;
    BlockNumber32 expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, BlockNumber32.wrap(uint32(block.number)));
    }

    function doExtend(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _extend(op, BlockNumber32.wrap(uint32(block.number)));
    }

    function setUp() public {
        btl = BlockNumber32.wrap(1000);
        expiresAt = BlockNumber32.wrap(uint32(block.number)) + btl;

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory createOp = Lib.createOp("hello", encodeMime128("text/plain"), attrs, btl);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // Validation — expiry not extended
    // =========================================================================

    function test_extend_sameExpiry_reverts() public {
        // btl that lands on the already-stored expiresAt: expiresAt - current
        Entity.Operation memory op = Lib.extendOp(testKey, expiresAt - BlockNumber32.wrap(uint32(block.number)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.ExpiryNotExtended.selector, testKey, expiresAt, expiresAt));
        this.doExtend(op);
    }

    function test_extend_lowerExpiry_reverts() public {
        // absolute target lower than current stored expiresAt
        BlockNumber32 lower = expiresAt - BlockNumber32.wrap(100);
        Entity.Operation memory op = Lib.extendOp(testKey, lower - BlockNumber32.wrap(uint32(block.number)));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.ExpiryNotExtended.selector, testKey, lower, expiresAt));
        this.doExtend(op);
    }

    // =========================================================================
    // State — commitment updates
    // =========================================================================

    function test_extend_updatesExpiresAt() public {
        BlockNumber32 newExpiry = expiresAt + BlockNumber32.wrap(500);
        Entity.Operation memory op = Lib.extendOp(testKey, newExpiry - BlockNumber32.wrap(uint32(block.number)));

        vm.prank(alice);
        this.doExtend(op);

        Entity.Commitment memory c = commitment(testKey);
        assertEq(BlockNumber32.unwrap(c.expiresAt), BlockNumber32.unwrap(newExpiry));
    }

    function test_extend_updatesUpdatedAt() public {
        vm.roll(block.number + 10);

        BlockNumber32 newExpiry = expiresAt + BlockNumber32.wrap(500);
        Entity.Operation memory op = Lib.extendOp(testKey, newExpiry - BlockNumber32.wrap(uint32(block.number)));

        vm.prank(alice);
        this.doExtend(op);

        Entity.Commitment memory c = commitment(testKey);
        assertEq(BlockNumber32.unwrap(c.updatedAt), uint32(block.number));
    }

    function test_extend_preservesCoreHashAndOwner() public {
        Entity.Commitment memory before_ = commitment(testKey);

        BlockNumber32 newExpiry = expiresAt + BlockNumber32.wrap(500);
        Entity.Operation memory op = Lib.extendOp(testKey, newExpiry - BlockNumber32.wrap(uint32(block.number)));

        vm.prank(alice);
        this.doExtend(op);

        Entity.Commitment memory after_ = commitment(testKey);
        assertEq(after_.coreHash, before_.coreHash);
        assertEq(after_.creator, before_.creator);
        assertEq(after_.owner, before_.owner);
        assertEq(BlockNumber32.unwrap(after_.createdAt), BlockNumber32.unwrap(before_.createdAt));
    }

    // =========================================================================
    // State — returns correct key
    // =========================================================================

    function test_extend_returnsEntityKey() public {
        BlockNumber32 newExpiry = expiresAt + BlockNumber32.wrap(500);
        Entity.Operation memory op = Lib.extendOp(testKey, newExpiry - BlockNumber32.wrap(uint32(block.number)));

        vm.prank(alice);
        (bytes32 returnedKey,) = this.doExtend(op);

        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_extend_entityHashUsesNewExpiry() public {
        BlockNumber32 newExpiry = expiresAt + BlockNumber32.wrap(500);
        Entity.Operation memory op = Lib.extendOp(testKey, newExpiry - BlockNumber32.wrap(uint32(block.number)));

        vm.prank(alice);
        (, bytes32 entityHash_) = this.doExtend(op);

        Entity.Commitment memory c = commitment(testKey);
        bytes32 expected = _wrapEntityHash(c.coreHash, c.owner, c.updatedAt, newExpiry);
        assertEq(entityHash_, expected);
    }

    function test_extend_differentExpiry_differentEntityHash() public {
        BlockNumber32 expiry1 = expiresAt + BlockNumber32.wrap(100);
        BlockNumber32 expiry2 = expiresAt + BlockNumber32.wrap(200);

        Entity.Operation memory op1 = Lib.extendOp(testKey, expiry1 - BlockNumber32.wrap(uint32(block.number)));
        vm.prank(alice);
        (, bytes32 hash1) = this.doExtend(op1);

        Entity.Operation memory op2 = Lib.extendOp(testKey, expiry2 - BlockNumber32.wrap(uint32(block.number)));
        vm.prank(alice);
        (, bytes32 hash2) = this.doExtend(op2);

        assertNotEq(hash1, hash2);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_extend_emitsEntityOperation() public {
        BlockNumber32 newExpiry = expiresAt + BlockNumber32.wrap(500);
        Entity.Operation memory op = Lib.extendOp(testKey, newExpiry - BlockNumber32.wrap(uint32(block.number)));

        vm.prank(alice);
        vm.recordLogs();
        (, bytes32 entityHash_) = this.doExtend(op);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EntityOperation.selector);
        assertEq(logs[0].topics[1], testKey);
        assertEq(logs[0].topics[2], bytes32(uint256(Entity.EXTEND)));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(alice))));
        (BlockNumber32 emittedExpiry, bytes32 emittedHash) = abi.decode(logs[0].data, (BlockNumber32, bytes32));
        assertEq(BlockNumber32.unwrap(emittedExpiry), BlockNumber32.unwrap(newExpiry));
        assertEq(emittedHash, entityHash_);
    }

    // =========================================================================
    // Guards — negative paths
    // =========================================================================

    function test_extend_revertsIfNotFound() public {
        BlockNumber32 newExpiry = expiresAt + BlockNumber32.wrap(500);
        Entity.Operation memory op =
            Lib.extendOp(keccak256("bogus"), newExpiry - BlockNumber32.wrap(uint32(block.number)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, keccak256("bogus")));
        this.doExtend(op);
    }

    function test_extend_revertsIfExpired() public {
        vm.roll(BlockNumber32.unwrap(expiresAt));
        BlockNumber32 newExpiry = expiresAt + BlockNumber32.wrap(500);
        Entity.Operation memory op = Lib.extendOp(testKey, newExpiry - BlockNumber32.wrap(uint32(block.number)));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityExpired.selector, testKey, expiresAt));
        this.doExtend(op);
    }

    function test_extend_revertsIfNotOwner() public {
        BlockNumber32 newExpiry = expiresAt + BlockNumber32.wrap(500);
        Entity.Operation memory op = Lib.extendOp(testKey, newExpiry - BlockNumber32.wrap(uint32(block.number)));
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Entity.NotOwner.selector, testKey, bob, alice));
        this.doExtend(op);
    }
}
