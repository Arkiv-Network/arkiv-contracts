// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {OpHarness} from "../../utils/harness/OpHarness.sol";

contract CreateTest is Test {
    OpHarness registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;

    function setUp() public {
        registry = new OpHarness();
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
        registry.exposed_create(op);
    }

    function test_create_expiryInPast_reverts() public {
        vm.roll(block.number + 100);

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, BlockNumber.wrap(1));

        vm.prank(alice);
        vm.expectRevert(); // ExpiryInPast
        registry.exposed_create(op);
    }

    function test_create_expiryOneBlockAhead_succeeds() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, currentBlock() + BlockNumber.wrap(1));

        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);
        assertTrue(key != bytes32(0));
    }

    // =========================================================================
    // State — commitment
    // =========================================================================

    function test_create_storesCommitment() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);

        EntityHashing.Commitment memory c = registry.getCommitment(key);
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
        assertEq(registry.nonces(alice), 0);

        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        registry.exposed_create(op);
        assertEq(registry.nonces(alice), 1);

        vm.prank(alice);
        registry.exposed_create(op);
        assertEq(registry.nonces(alice), 2);
    }

    function test_create_independentNoncesPerSender() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        registry.exposed_create(op);

        vm.prank(bob);
        registry.exposed_create(op);

        assertEq(registry.nonces(alice), 1);
        assertEq(registry.nonces(bob), 1);
    }

    // =========================================================================
    // State — entity key determinism
    // =========================================================================

    function test_create_keyMatchesEntityKeyFunction() public {
        bytes32 expectedKey = registry.entityKey(alice, 0);

        EntityHashing.Op memory op = _defaultOp();
        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);

        assertEq(key, expectedKey);
    }

    function test_create_secondKeyMatchesNonce1() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        registry.exposed_create(op);

        bytes32 expectedKey = registry.entityKey(alice, 1);
        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);

        assertEq(key, expectedKey);
    }

    function test_create_differentSenders_differentKeys() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        (bytes32 keyAlice,) = registry.exposed_create(op);

        vm.prank(bob);
        (bytes32 keyBob,) = registry.exposed_create(op);

        assertNotEq(keyAlice, keyBob);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_create_emitsEntityCreated() public {
        EntityHashing.Op memory op = _defaultOp();
        bytes32 expectedKey = registry.entityKey(alice, 0);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit EntityCreated(expectedKey, alice, expiresAt, bytes32(0));
        registry.exposed_create(op);
    }

    event EntityCreated(bytes32 indexed entityKey, address indexed owner, BlockNumber expiresAt, bytes32 entityHash);

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_create_coreHashMatchesManualComputation() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = Lib.uintAttr("count", 42);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, expiresAt);

        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);

        EntityHashing.Commitment memory c = registry.getCommitment(key);
        bytes32 expected = registry.exposed_coreHash(key, alice, c.createdAt, "text/plain", "hello", attrs);
        assertEq(c.coreHash, expected);
    }

    function test_create_entityHashMatchesManualComputation() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        (bytes32 key, bytes32 entityHash_) = registry.exposed_create(op);

        EntityHashing.Commitment memory c = registry.getCommitment(key);
        bytes32 expected = registry.exposed_entityHash(c.coreHash, alice, c.updatedAt, c.expiresAt);
        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Edge cases
    // =========================================================================

    function test_create_emptyPayloadAndAttributes() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("", "text/plain", attrs, expiresAt);

        vm.prank(alice);
        (bytes32 key, bytes32 entityHash_) = registry.exposed_create(op);

        assertTrue(key != bytes32(0));
        assertTrue(entityHash_ != bytes32(0));
    }
}
