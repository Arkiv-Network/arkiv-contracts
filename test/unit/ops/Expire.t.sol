// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract ExpireTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    function _validateAttributes(EntityHashing.Attribute[] calldata) internal pure override {}

    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doExpire(bytes32 key) external returns (bytes32, bytes32) {
        return _expire(key, currentBlock());
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

    function test_expire_nonExistentEntity_reverts() public {
        bytes32 bogus = keccak256("bogus");

        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, bogus));
        this.doExpire(bogus);
    }

    // =========================================================================
    // Validation — entity not yet expired
    // =========================================================================

    function test_expire_notYetExpired_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotExpired.selector, testKey, expiresAt));
        this.doExpire(testKey);
    }

    function test_expire_oneBlockBeforeExpiry_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt) - 1);

        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotExpired.selector, testKey, expiresAt));
        this.doExpire(testKey);
    }

    // =========================================================================
    // Callable by anyone
    // =========================================================================

    function test_expire_callableByNonOwner() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        // bob (not the owner) can expire alice's entity.
        vm.prank(bob);
        (bytes32 returnedKey,) = this.doExpire(testKey);

        assertEq(returnedKey, testKey);
        assertEq(getCommitment(testKey).creator, address(0));
    }

    function test_expire_callableByOwner() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        vm.prank(alice);
        (bytes32 returnedKey,) = this.doExpire(testKey);

        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // State — commitment removed
    // =========================================================================

    function test_expire_removesCommitment() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        this.doExpire(testKey);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        assertEq(c.creator, address(0));
        assertEq(c.owner, address(0));
        assertEq(c.coreHash, bytes32(0));
        assertEq(BlockNumber.unwrap(c.createdAt), 0);
        assertEq(BlockNumber.unwrap(c.updatedAt), 0);
        assertEq(BlockNumber.unwrap(c.expiresAt), 0);
    }

    function test_expire_doubleExpire_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        this.doExpire(testKey);

        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, testKey));
        this.doExpire(testKey);
    }

    // =========================================================================
    // Expiry boundary — exactly at expiresAt
    // =========================================================================

    function test_expire_atExactExpiryBlock_succeeds() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        (bytes32 returnedKey,) = this.doExpire(testKey);
        assertEq(returnedKey, testKey);
    }

    function test_expire_afterExpiryBlock_succeeds() public {
        vm.roll(BlockNumber.unwrap(expiresAt) + 100);

        (bytes32 returnedKey,) = this.doExpire(testKey);
        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_expire_returnsSnapshotHash() public {
        // Compute expected hash from commitment before expiry.
        EntityHashing.Commitment memory c = getCommitment(testKey);
        bytes32 expected = _entityHash(c.coreHash, c.owner, c.updatedAt, c.expiresAt);

        vm.roll(BlockNumber.unwrap(expiresAt));

        (, bytes32 entityHash_) = this.doExpire(testKey);
        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_expire_emitsEntityExpired() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        vm.expectEmit(true, true, false, false);
        emit EntityExpired(testKey, alice, bytes32(0));
        this.doExpire(testKey);
    }
}
