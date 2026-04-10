// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

/// @dev Tests _create logic (expiry, commitment, hashing, events) with a
/// stubbed _createEntityKey so key generation is isolated.
contract CreateTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;

    bytes32 constant STUB_KEY = keccak256("stub-entity-key");

    function _createEntityKey(address) internal pure override returns (bytes32) {
        return STUB_KEY;
    }

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
        assertEq(key, STUB_KEY);
    }

    // =========================================================================
    // State — commitment
    // =========================================================================

    function test_create_storesCommitment() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        this.doCreate(op);

        EntityHashing.Commitment memory c = getCommitment(STUB_KEY);
        assertEq(c.creator, alice);
        assertEq(c.owner, alice);
        assertEq(BlockNumber.unwrap(c.createdAt), uint32(block.number));
        assertEq(BlockNumber.unwrap(c.updatedAt), uint32(block.number));
        assertEq(BlockNumber.unwrap(c.expiresAt), BlockNumber.unwrap(expiresAt));
        assertTrue(c.coreHash != bytes32(0));
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_create_emitsEntityCreated() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit EntityCreated(STUB_KEY, alice, expiresAt, bytes32(0));
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
        this.doCreate(op);

        EntityHashing.Commitment memory c = getCommitment(STUB_KEY);
        bytes32 expected = this.hashCore(STUB_KEY, alice, c.createdAt, "text/plain", "hello", attrs);
        assertEq(c.coreHash, expected);
    }

    function test_create_entityHashMatchesManualComputation() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        (, bytes32 entityHash_) = this.doCreate(op);

        EntityHashing.Commitment memory c = getCommitment(STUB_KEY);
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

        assertEq(key, STUB_KEY);
        assertTrue(entityHash_ != bytes32(0));
    }
}

