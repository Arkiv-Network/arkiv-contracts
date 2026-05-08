// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber32} from "../../../contracts/types/BlockNumber32.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../contracts/Entity.sol";
import {EntityRegistry} from "../../../contracts/EntityRegistry.sol";
import {encodeMime128} from "../../../contracts/types/Mime128.sol";

/// @dev Tests _create logic (expiry, commitment, events) with stubbed key
/// generation and hash computation so the test focuses on state transitions.
contract CreateTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber32 btl;

    bytes32 constant STUB_KEY = keccak256("stub-entity-key");
    bytes32 constant STUB_CORE_HASH = keccak256("stub-core-hash");
    bytes32 constant STUB_ENTITY_HASH = keccak256("stub-entity-hash");

    function _createEntityKey(address) internal pure override returns (bytes32) {
        return STUB_KEY;
    }

    function _computeEntityHash(
        bytes32,
        address,
        BlockNumber32,
        address,
        BlockNumber32,
        BlockNumber32,
        Entity.Operation calldata
    ) internal pure override returns (bytes32, bytes32) {
        return (STUB_CORE_HASH, STUB_ENTITY_HASH);
    }

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, BlockNumber32.wrap(uint32(block.number)));
    }

    function setUp() public {
        btl = BlockNumber32.wrap(1000);
    }

    function _defaultOp() internal view returns (Entity.Operation memory) {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        return Lib.createOp("hello", encodeMime128("text/plain"), attrs, btl);
    }

    // =========================================================================
    // Validation — expiry
    // =========================================================================

    function test_create_zeroBtl_reverts() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.createOp("hello", encodeMime128("text/plain"), attrs, BlockNumber32.wrap(0));

        vm.prank(alice);
        vm.expectRevert(Entity.ZeroBtl.selector);
        this.doCreate(op);
    }

    function test_create_btlOne_succeeds() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.createOp("hello", encodeMime128("text/plain"), attrs, BlockNumber32.wrap(1));

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
        assertEq(BlockNumber32.unwrap(c.createdAt), uint32(block.number));
        assertEq(BlockNumber32.unwrap(c.updatedAt), uint32(block.number));
        assertEq(BlockNumber32.unwrap(c.expiresAt), uint32(block.number) + BlockNumber32.unwrap(btl));
        assertEq(c.coreHash, STUB_CORE_HASH);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_create_emitsEntityOperation() public {
        Entity.Operation memory op = _defaultOp();

        vm.prank(alice);
        vm.recordLogs();
        this.doCreate(op);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EntityOperation.selector);
        assertEq(logs[0].topics[1], STUB_KEY);
        assertEq(logs[0].topics[2], bytes32(uint256(Entity.CREATE)));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(alice))));
        (BlockNumber32 emittedExpiry, bytes32 emittedHash) = abi.decode(logs[0].data, (BlockNumber32, bytes32));
        assertEq(BlockNumber32.unwrap(emittedExpiry), uint32(block.number) + BlockNumber32.unwrap(btl));
        assertEq(emittedHash, STUB_ENTITY_HASH);
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
