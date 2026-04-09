// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract CreateTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;

    // Stub out validation — tested separately in ValidateAttributes.t.sol.
    function _validateAttributes(EntityHashing.Attribute[] calldata) internal pure override {}

    // Calldata wrappers for internal/library functions.
    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
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
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _defaultOp() internal view returns (EntityHashing.Op memory) {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        return Lib.createOp("hello", "text/plain", attrs, expiresAt);
    }

    // =========================================================================
    // Validation — expiry
    // =========================================================================

    function test_create_expiryEqualToCurrentBlock_reverts() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, currentBlock());

        vm.prank(alice);
        vm.expectRevert(); // ExpiryInPast
        this.doCreate(op);
    }

    function test_create_expiryInPast_reverts() public {
        vm.roll(block.number + 100);

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, BlockNumber.wrap(1));

        vm.prank(alice);
        vm.expectRevert(); // ExpiryInPast
        this.doCreate(op);
    }

    function test_create_expiryOneBlockAhead_succeeds() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, currentBlock() + BlockNumber.wrap(1));

        vm.prank(alice);
        (bytes32 key,) = this.doCreate(op);
        assertTrue(key != bytes32(0));
    }

    // =========================================================================
    // State — commitment
    // =========================================================================

    function test_create_storesCommitment() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        (bytes32 key,) = this.doCreate(op);

        EntityHashing.Commitment memory c = getCommitment(key);
        assertEq(c.creator, alice);
        assertEq(c.owner, alice);
        assertEq(BlockNumber.unwrap(c.createdAt), uint32(block.number));
        assertEq(BlockNumber.unwrap(c.updatedAt), uint32(block.number));
        assertEq(BlockNumber.unwrap(c.expiresAt), BlockNumber.unwrap(expiresAt));
        assertTrue(c.coreHash != bytes32(0));
    }

    // =========================================================================
    // State — nonce
    // =========================================================================

    function test_create_incrementsNonce() public {
        assertEq(nonces[alice], 0);

        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        this.doCreate(op);
        assertEq(nonces[alice], 1);

        vm.prank(alice);
        this.doCreate(op);
        assertEq(nonces[alice], 2);
    }

    function test_create_independentNoncesPerSender() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        this.doCreate(op);

        vm.prank(bob);
        this.doCreate(op);

        assertEq(nonces[alice], 1);
        assertEq(nonces[bob], 1);
    }

    // =========================================================================
    // State — entity key determinism
    // =========================================================================

    function test_create_keyMatchesEntityKeyFunction() public {
        bytes32 expectedKey = entityKey(alice, 0);

        EntityHashing.Op memory op = _defaultOp();
        vm.prank(alice);
        (bytes32 key,) = this.doCreate(op);

        assertEq(key, expectedKey);
    }

    function test_create_secondKeyMatchesNonce1() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        this.doCreate(op);

        bytes32 expectedKey = entityKey(alice, 1);
        vm.prank(alice);
        (bytes32 key,) = this.doCreate(op);

        assertEq(key, expectedKey);
    }

    function test_create_differentSenders_differentKeys() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        (bytes32 keyAlice,) = this.doCreate(op);

        vm.prank(bob);
        (bytes32 keyBob,) = this.doCreate(op);

        assertNotEq(keyAlice, keyBob);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_create_emitsEntityCreated() public {
        EntityHashing.Op memory op = _defaultOp();
        bytes32 expectedKey = entityKey(alice, 0);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit EntityCreated(expectedKey, alice, expiresAt, bytes32(0));
        this.doCreate(op);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_create_coreHashMatchesManualComputation() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = Lib.uintAttr("count", 42);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, expiresAt);

        vm.prank(alice);
        (bytes32 key,) = this.doCreate(op);

        EntityHashing.Commitment memory c = getCommitment(key);
        bytes32 expected = this.hashCore(key, alice, c.createdAt, "text/plain", "hello", attrs);
        assertEq(c.coreHash, expected);
    }

    function test_create_entityHashMatchesManualComputation() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        (bytes32 key, bytes32 entityHash_) = this.doCreate(op);

        EntityHashing.Commitment memory c = getCommitment(key);
        bytes32 expected = _entityHash(c.coreHash, alice, c.updatedAt, c.expiresAt);
        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Edge cases
    // =========================================================================

    function test_create_emptyPayloadAndAttributes() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("", "text/plain", attrs, expiresAt);

        vm.prank(alice);
        (bytes32 key, bytes32 entityHash_) = this.doCreate(op);

        assertTrue(key != bytes32(0));
        assertTrue(entityHash_ != bytes32(0));
    }
}
