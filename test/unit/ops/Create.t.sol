// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../src/Entity.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {encodeMime128} from "../../../src/types/Mime128.sol";

/// @dev Tests _create logic (expiry, commitment, events) with stubbed key
/// generation and hash computation so the test focuses on state transitions.
contract CreateTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;

    bytes32 constant STUB_KEY = keccak256("stub-entity-key");
    bytes32 constant STUB_CORE_HASH = keccak256("stub-core-hash");
    bytes32 constant STUB_ENTITY_HASH = keccak256("stub-entity-hash");

    function _createEntityKey(address) internal pure override returns (bytes32) {
        return STUB_KEY;
    }

    function _computeEntityHash(
        bytes32,
        address,
        BlockNumber,
        address,
        BlockNumber,
        BlockNumber,
        Entity.Operation calldata
    ) internal pure override returns (bytes32, bytes32) {
        return (STUB_CORE_HASH, STUB_ENTITY_HASH);
    }

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);
    }

    function _defaultOp() internal view returns (Entity.Operation memory) {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        return Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
    }

    // =========================================================================
    // Validation — expiry
    // =========================================================================

    function test_create_expiryEqualToCurrentBlock_reverts() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.createOp("hello", encodeMime128("text/plain"), attrs, currentBlock());

        vm.prank(alice);
        vm.expectRevert(); // ExpiryInPast
        this.doCreate(op);
    }

    function test_create_expiryInPast_reverts() public {
        vm.roll(block.number + 100);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.createOp("hello", encodeMime128("text/plain"), attrs, BlockNumber.wrap(1));

        vm.prank(alice);
        vm.expectRevert(); // ExpiryInPast
        this.doCreate(op);
    }

    function test_create_expiryOneBlockAhead_succeeds() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op =
            Lib.createOp("hello", encodeMime128("text/plain"), attrs, currentBlock() + BlockNumber.wrap(1));

        vm.prank(alice);
        (bytes32 key,) = this.doCreate(op);
        assertEq(key, STUB_KEY);
    }

    // =========================================================================
    // State — commitment
    // =========================================================================

    function test_create_storesCommitment() public {
        Entity.Operation memory op = _defaultOp();

        vm.prank(alice);
        this.doCreate(op);

        Entity.Commitment memory c = commitment(STUB_KEY);
        assertEq(c.creator, alice);
        assertEq(c.owner, alice);
        assertEq(BlockNumber.unwrap(c.createdAt), uint32(block.number));
        assertEq(BlockNumber.unwrap(c.updatedAt), uint32(block.number));
        assertEq(BlockNumber.unwrap(c.expiresAt), BlockNumber.unwrap(expiresAt));
        assertEq(c.coreHash, STUB_CORE_HASH);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_create_emitsEntityOp() public {
        Entity.Operation memory op = _defaultOp();

        vm.prank(alice);
        vm.expectEmit(true, true, true, true);
        emit EntityOp(STUB_KEY, Entity.CREATE, alice, expiresAt, STUB_ENTITY_HASH);
        this.doCreate(op);
    }

    // =========================================================================
    // Return values
    // =========================================================================

    function test_create_returnsKeyAndEntityHash() public {
        Entity.Operation memory op = _defaultOp();

        vm.prank(alice);
        (bytes32 key, bytes32 entityHash_) = this.doCreate(op);

        assertEq(key, STUB_KEY);
        assertEq(entityHash_, STUB_ENTITY_HASH);
    }
}
