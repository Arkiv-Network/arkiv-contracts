// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";

/// @dev Tests _guardEntityMutation in isolation.
contract GuardEntityMutationTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doGuard(bytes32 key, BlockNumber current) external view {
        EntityHashing.Commitment storage c = _commitments[key];
        _requireExists(key, c);
        _requireActive(key, c, current);
        _requireOwner(key, c);
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(op);
    }

    // =========================================================================
    // Entity not found
    // =========================================================================

    function test_nonExistentEntity_reverts() public {
        bytes32 bogus = keccak256("bogus");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, bogus));
        this.doGuard(bogus, currentBlock());
    }

    // =========================================================================
    // Expired entity
    // =========================================================================

    function test_expiredEntity_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt) + 1);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doGuard(testKey, currentBlock());
    }

    function test_atExpiryBlock_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doGuard(testKey, currentBlock());
    }

    // =========================================================================
    // Not owner
    // =========================================================================

    function test_notOwner_reverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.NotOwner.selector, testKey, bob, alice));
        this.doGuard(testKey, currentBlock());
    }

    // =========================================================================
    // Happy path
    // =========================================================================

    function test_validOwner_succeeds() public {
        vm.prank(alice);
        this.doGuard(testKey, currentBlock());
    }
}
