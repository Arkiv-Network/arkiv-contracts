// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract UpdateTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    // Calldata wrappers.
    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doUpdate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _update(op, currentBlock());
    }

    function hashCore(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        string calldata contentType,
        bytes calldata payload,
        EntityHashing.Attribute[] calldata attributes
    ) external pure returns (bytes32) {
        return EntityHashing.coreHash(key, creator, createdAt, contentType, payload, attributes);
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        // Create an entity owned by alice.
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory createOp = Lib.createOp("hello", "text/plain", attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _simpleUpdateOp() internal view returns (EntityHashing.Op memory) {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        return Lib.updateOp(testKey, "world", "text/plain", attrs);
    }

    // =========================================================================
    // Validation — entity not found
    // =========================================================================

    function test_update_nonExistentEntity_reverts() public {
        bytes32 bogus = keccak256("bogus");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.updateOp(bogus, "data", "text/plain", attrs);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, bogus));
        this.doUpdate(op);
    }

    // =========================================================================
    // Validation — expired entity
    // =========================================================================

    function test_update_expiredEntity_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt) + 1);

        EntityHashing.Op memory op = _simpleUpdateOp();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doUpdate(op);
    }

    function test_update_atExpiryBlock_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        EntityHashing.Op memory op = _simpleUpdateOp();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doUpdate(op);
    }

    // =========================================================================
    // Validation — not owner
    // =========================================================================

    function test_update_notOwner_reverts() public {
        EntityHashing.Op memory op = _simpleUpdateOp();

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.NotOwner.selector, testKey, bob, alice));
        this.doUpdate(op);
    }

    // =========================================================================
    // State — commitment updates
    // =========================================================================

    function test_update_updatesCoreHash() public {
        EntityHashing.Commitment memory before_ = getCommitment(testKey);

        EntityHashing.Op memory op = _simpleUpdateOp();
        vm.prank(alice);
        this.doUpdate(op);

        EntityHashing.Commitment memory after_ = getCommitment(testKey);
        assertNotEq(after_.coreHash, before_.coreHash);
    }

    function test_update_updatesUpdatedAt() public {
        vm.roll(block.number + 10);

        EntityHashing.Op memory op = _simpleUpdateOp();
        vm.prank(alice);
        this.doUpdate(op);

        EntityHashing.Commitment memory after_ = getCommitment(testKey);
        assertEq(BlockNumber.unwrap(after_.updatedAt), uint32(block.number));
    }

    function test_update_preservesImmutableFields() public {
        EntityHashing.Commitment memory before_ = getCommitment(testKey);

        EntityHashing.Op memory op = _simpleUpdateOp();
        vm.prank(alice);
        this.doUpdate(op);

        EntityHashing.Commitment memory after_ = getCommitment(testKey);
        assertEq(after_.creator, before_.creator);
        assertEq(after_.owner, before_.owner);
        assertEq(BlockNumber.unwrap(after_.createdAt), BlockNumber.unwrap(before_.createdAt));
        assertEq(BlockNumber.unwrap(after_.expiresAt), BlockNumber.unwrap(before_.expiresAt));
    }

    // =========================================================================
    // State — returns correct key
    // =========================================================================

    function test_update_returnsEntityKey() public {
        EntityHashing.Op memory op = _simpleUpdateOp();
        vm.prank(alice);
        (bytes32 returnedKey,) = this.doUpdate(op);

        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_update_coreHashMatchesManualComputation() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = Lib.uintAttr("count", 99);
        EntityHashing.Op memory op = Lib.updateOp(testKey, "new payload", "text/plain", attrs);

        vm.prank(alice);
        this.doUpdate(op);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        bytes32 expected = this.hashCore(testKey, c.creator, c.createdAt, "text/plain", "new payload", attrs);
        assertEq(c.coreHash, expected);
    }

    function test_update_entityHashMatchesManualComputation() public {
        EntityHashing.Op memory op = _simpleUpdateOp();

        vm.prank(alice);
        (, bytes32 entityHash_) = this.doUpdate(op);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        bytes32 expected =
            _hashTypedDataV4(EntityHashing.entityStructHash(c.coreHash, c.owner, c.updatedAt, c.expiresAt));
        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_update_emitsEntityUpdated() public {
        EntityHashing.Op memory op = _simpleUpdateOp();

        vm.prank(alice);
        vm.expectEmit(true, true, true, false);
        emit EntityUpdated(testKey, alice, expiresAt, bytes32(0));
        this.doUpdate(op);
    }

    // =========================================================================
    // Edge cases
    // =========================================================================

    function test_update_sameContentProducesSameCoreHash() public {
        EntityHashing.Commitment memory before_ = getCommitment(testKey);

        // Update with the exact same content as the original create.
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.updateOp(testKey, "hello", "text/plain", attrs);

        vm.prank(alice);
        this.doUpdate(op);

        EntityHashing.Commitment memory after_ = getCommitment(testKey);
        assertEq(after_.coreHash, before_.coreHash);
    }

    function test_update_emptyPayloadAndAttributes() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.updateOp(testKey, "", "text/plain", attrs);

        vm.prank(alice);
        (bytes32 key, bytes32 entityHash_) = this.doUpdate(op);

        assertEq(key, testKey);
        assertTrue(entityHash_ != bytes32(0));
    }

    function test_update_multipleUpdatesChain() public {
        // First update.
        EntityHashing.Attribute[] memory attrs1 = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op1 = Lib.updateOp(testKey, "v2", "text/plain", attrs1);
        vm.prank(alice);
        this.doUpdate(op1);

        EntityHashing.Commitment memory mid = getCommitment(testKey);

        // Second update with different content.
        EntityHashing.Attribute[] memory attrs2 = new EntityHashing.Attribute[](1);
        attrs2[0] = Lib.uintAttr("version", 3);
        EntityHashing.Op memory op2 = Lib.updateOp(testKey, "v3", "application/json", attrs2);
        vm.prank(alice);
        this.doUpdate(op2);

        EntityHashing.Commitment memory final_ = getCommitment(testKey);
        assertNotEq(final_.coreHash, mid.coreHash);
    }
}
