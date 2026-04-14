// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";

/// @dev Tests _guardEntityExpiry in isolation.
contract GuardEntityExpiryTest is Test, EntityRegistry {
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
        _requireExpired(key, c, current);
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

        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, bogus));
        this.doGuard(bogus, currentBlock());
    }

    // =========================================================================
    // Entity not yet expired
    // =========================================================================

    function test_notYetExpired_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotExpired.selector, testKey, expiresAt));
        this.doGuard(testKey, currentBlock());
    }

    function test_oneBlockBeforeExpiry_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt) - 1);

        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotExpired.selector, testKey, expiresAt));
        this.doGuard(testKey, currentBlock());
    }

    // =========================================================================
    // Happy path — expired
    // =========================================================================

    function test_atExactExpiryBlock_succeeds() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        this.doGuard(testKey, currentBlock());
    }

    function test_afterExpiryBlock_succeeds() public {
        vm.roll(BlockNumber.unwrap(expiresAt) + 100);

        this.doGuard(testKey, currentBlock());
    }

    // =========================================================================
    // Callable by anyone
    // =========================================================================

    function test_callableByNonOwner() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        vm.prank(bob);
        this.doGuard(testKey, currentBlock());
    }
}
