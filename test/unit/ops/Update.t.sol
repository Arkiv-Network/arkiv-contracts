// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/types/BlockNumber.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../src/Entity.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {Mime128, encodeMime128} from "../../../src/types/Mime128.sol";

contract UpdateTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    Mime128 textPlain;
    Mime128 appJson;

    // Calldata wrappers.
    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doUpdate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _update(op, currentBlock());
    }

    function hashCore(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        Mime128 calldata contentType,
        bytes calldata payload,
        Entity.Attribute[] calldata attributes
    ) external pure returns (bytes32) {
        return Entity.coreHash(key, creator, createdAt, contentType, payload, attributes);
    }

    function setUp() public {
        textPlain = encodeMime128("text/plain");
        appJson = encodeMime128("application/json");

        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        // Create an entity owned by alice.
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory createOp = Lib.createOp("hello", textPlain, attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _simpleUpdateOp() internal view returns (Entity.Operation memory) {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        return Lib.updateOp(testKey, "world", textPlain, attrs);
    }

    // =========================================================================
    // State — commitment updates
    // =========================================================================

    function test_update_updatesCoreHash() public {
        Entity.Commitment memory before_ = commitment(testKey);

        Entity.Operation memory op = _simpleUpdateOp();
        vm.prank(alice);
        this.doUpdate(op);

        Entity.Commitment memory after_ = commitment(testKey);
        assertNotEq(after_.coreHash, before_.coreHash);
    }

    function test_update_updatesUpdatedAt() public {
        vm.roll(block.number + 10);

        Entity.Operation memory op = _simpleUpdateOp();
        vm.prank(alice);
        this.doUpdate(op);

        Entity.Commitment memory after_ = commitment(testKey);
        assertEq(BlockNumber.unwrap(after_.updatedAt), uint32(block.number));
    }

    function test_update_preservesImmutableFields() public {
        Entity.Commitment memory before_ = commitment(testKey);

        Entity.Operation memory op = _simpleUpdateOp();
        vm.prank(alice);
        this.doUpdate(op);

        Entity.Commitment memory after_ = commitment(testKey);
        assertEq(after_.creator, before_.creator);
        assertEq(after_.owner, before_.owner);
        assertEq(BlockNumber.unwrap(after_.createdAt), BlockNumber.unwrap(before_.createdAt));
        assertEq(BlockNumber.unwrap(after_.expiresAt), BlockNumber.unwrap(before_.expiresAt));
    }

    // =========================================================================
    // State — returns correct key
    // =========================================================================

    function test_update_returnsEntityKey() public {
        Entity.Operation memory op = _simpleUpdateOp();
        vm.prank(alice);
        (bytes32 returnedKey,) = this.doUpdate(op);

        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_update_coreHashMatchesManualComputation() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](1);
        attrs[0] = Lib.uintAttr("count", 99);
        Entity.Operation memory op = Lib.updateOp(testKey, "new payload", textPlain, attrs);

        vm.prank(alice);
        this.doUpdate(op);

        Entity.Commitment memory c = commitment(testKey);
        bytes32 expected = this.hashCore(testKey, c.creator, c.createdAt, textPlain, "new payload", attrs);
        assertEq(c.coreHash, expected);
    }

    function test_update_entityHashMatchesManualComputation() public {
        Entity.Operation memory op = _simpleUpdateOp();

        vm.prank(alice);
        (, bytes32 entityHash_) = this.doUpdate(op);

        Entity.Commitment memory c = commitment(testKey);
        bytes32 expected = _wrapEntityHash(c.coreHash, c.owner, c.updatedAt, c.expiresAt);
        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_update_emitsEntityOperation() public {
        Entity.Operation memory op = _simpleUpdateOp();

        vm.prank(alice);
        vm.recordLogs();
        (, bytes32 entityHash_) = this.doUpdate(op);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EntityOperation.selector);
        assertEq(logs[0].topics[1], testKey);
        assertEq(logs[0].topics[2], bytes32(uint256(Entity.UPDATE)));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(alice))));
        (BlockNumber emittedExpiry, bytes32 emittedHash) = abi.decode(logs[0].data, (BlockNumber, bytes32));
        assertEq(BlockNumber.unwrap(emittedExpiry), BlockNumber.unwrap(expiresAt));
        assertEq(emittedHash, entityHash_);
    }

    // =========================================================================
    // Edge cases
    // =========================================================================

    function test_update_sameContentProducesSameCoreHash() public {
        Entity.Commitment memory before_ = commitment(testKey);

        // Update with the exact same content as the original create.
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.updateOp(testKey, "hello", textPlain, attrs);

        vm.prank(alice);
        this.doUpdate(op);

        Entity.Commitment memory after_ = commitment(testKey);
        assertEq(after_.coreHash, before_.coreHash);
    }

    function test_update_emptyPayloadAndAttributes() public {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.updateOp(testKey, "", textPlain, attrs);

        vm.prank(alice);
        (bytes32 key, bytes32 entityHash_) = this.doUpdate(op);

        assertEq(key, testKey);
        assertTrue(entityHash_ != bytes32(0));
    }

    function test_update_multipleUpdatesChain() public {
        // First update.
        Entity.Attribute[] memory attrs1 = new Entity.Attribute[](0);
        Entity.Operation memory op1 = Lib.updateOp(testKey, "v2", textPlain, attrs1);
        vm.prank(alice);
        this.doUpdate(op1);

        Entity.Commitment memory mid = commitment(testKey);

        // Second update with different content.
        Entity.Attribute[] memory attrs2 = new Entity.Attribute[](1);
        attrs2[0] = Lib.uintAttr("version", 3);
        Entity.Operation memory op2 = Lib.updateOp(testKey, "v3", appJson, attrs2);
        vm.prank(alice);
        this.doUpdate(op2);

        Entity.Commitment memory final_ = commitment(testKey);
        assertNotEq(final_.coreHash, mid.coreHash);
    }

    // =========================================================================
    // Guards — negative paths
    // =========================================================================

    function test_update_revertsIfNotFound() public {
        Entity.Operation memory op = _simpleUpdateOp();
        op.entityKey = keccak256("bogus");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, op.entityKey));
        this.doUpdate(op);
    }

    function test_update_revertsIfExpired() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        Entity.Operation memory op = _simpleUpdateOp();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityExpired.selector, testKey, expiresAt));
        this.doUpdate(op);
    }

    function test_update_revertsIfNotOwner() public {
        Entity.Operation memory op = _simpleUpdateOp();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Entity.NotOwner.selector, testKey, bob, alice));
        this.doUpdate(op);
    }
}
