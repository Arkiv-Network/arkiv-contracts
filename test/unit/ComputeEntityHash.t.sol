// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {Entity} from "../../src/Entity.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {Mime128, encodeMime128} from "../../src/types/Mime128.sol";

/// @dev Tests _computeEntityHash in isolation — verifies the two-level EIP-712
/// hash (coreHash + entityHash) matches manual computation.
contract ComputeEntityHashTest is Test, EntityRegistry {
    address alice = makeAddr("alice");

    Mime128 textPlain;

    function setUp() public {
        textPlain = encodeMime128("text/plain");
    }

    function doComputeEntityHash(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        address owner,
        BlockNumber updatedAt,
        BlockNumber expiresAt,
        Entity.Op calldata op
    ) external view returns (bytes32, bytes32) {
        return _computeEntityHash(key, creator, createdAt, owner, updatedAt, expiresAt, op);
    }

    function doCoreHash(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        Mime128 calldata contentType,
        bytes calldata payload,
        Entity.Attribute[] calldata attributes
    ) external pure returns (bytes32) {
        return Entity.coreHash(key, creator, createdAt, contentType, payload, attributes);
    }

    // =========================================================================
    // Core hash correctness
    // =========================================================================

    function test_coreHashMatchesLibrary() public {
        bytes32 key = keccak256("key");
        BlockNumber current = BlockNumber.wrap(100);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](1);
        attrs[0] = Lib.uintAttr("count", 42);
        Entity.Op memory op = Lib.createOp("hello", textPlain, attrs, currentBlock() + BlockNumber.wrap(1000));

        (bytes32 coreHash_,) = this.doComputeEntityHash(key, alice, current, alice, current, op.expiresAt, op);
        bytes32 expected = this.doCoreHash(key, alice, current, textPlain, "hello", attrs);

        assertEq(coreHash_, expected);
    }

    // =========================================================================
    // Entity hash correctness — two-level structure
    // =========================================================================

    function test_entityHashWrapsWithDomainSeparator() public {
        bytes32 key = keccak256("key");
        BlockNumber current = BlockNumber.wrap(100);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Op memory op = Lib.createOp("hello", textPlain, attrs, currentBlock() + BlockNumber.wrap(1000));

        (bytes32 coreHash_, bytes32 entityHash_) =
            this.doComputeEntityHash(key, alice, current, alice, current, op.expiresAt, op);

        // Verify entityHash matches _wrapEntityHash for the same inputs
        bytes32 expected = _wrapEntityHash(coreHash_, alice, current, op.expiresAt);

        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Determinism
    // =========================================================================

    function test_deterministic() public {
        bytes32 key = keccak256("key");
        BlockNumber current = BlockNumber.wrap(100);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Op memory op = Lib.createOp("hello", textPlain, attrs, currentBlock() + BlockNumber.wrap(1000));

        (bytes32 coreA, bytes32 entityA) =
            this.doComputeEntityHash(key, alice, current, alice, current, op.expiresAt, op);
        (bytes32 coreB, bytes32 entityB) =
            this.doComputeEntityHash(key, alice, current, alice, current, op.expiresAt, op);

        assertEq(coreA, coreB);
        assertEq(entityA, entityB);
    }

    // =========================================================================
    // Different inputs produce different hashes
    // =========================================================================

    function test_differentPayload_differs() public {
        bytes32 key = keccak256("key");
        BlockNumber current = BlockNumber.wrap(100);
        BlockNumber expiry = currentBlock() + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Op memory opA = Lib.createOp("hello", textPlain, attrs, expiry);
        Entity.Op memory opB = Lib.createOp("world", textPlain, attrs, expiry);

        (bytes32 coreA,) = this.doComputeEntityHash(key, alice, current, alice, current, opA.expiresAt, opA);
        (bytes32 coreB,) = this.doComputeEntityHash(key, alice, current, alice, current, opB.expiresAt, opB);

        assertNotEq(coreA, coreB);
    }

    function test_differentExpiry_entityHashDiffers() public {
        bytes32 key = keccak256("key");
        BlockNumber current = BlockNumber.wrap(100);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Op memory opA = Lib.createOp("hello", textPlain, attrs, BlockNumber.wrap(500));
        Entity.Op memory opB = Lib.createOp("hello", textPlain, attrs, BlockNumber.wrap(600));

        (bytes32 coreA, bytes32 entityA) =
            this.doComputeEntityHash(key, alice, current, alice, current, opA.expiresAt, opA);
        (bytes32 coreB, bytes32 entityB) =
            this.doComputeEntityHash(key, alice, current, alice, current, opB.expiresAt, opB);

        // Same content → same coreHash
        assertEq(coreA, coreB);
        // Different expiry → different entityHash
        assertNotEq(entityA, entityB);
    }

    function test_differentAttributes_coreHashDiffers() public {
        bytes32 key = keccak256("key");
        BlockNumber current = BlockNumber.wrap(100);
        BlockNumber expiry = currentBlock() + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrsA = new Entity.Attribute[](1);
        attrsA[0] = Lib.uintAttr("count", 1);

        Entity.Attribute[] memory attrsB = new Entity.Attribute[](1);
        attrsB[0] = Lib.uintAttr("count", 2);

        Entity.Op memory opA = Lib.createOp("hello", textPlain, attrsA, expiry);
        Entity.Op memory opB = Lib.createOp("hello", textPlain, attrsB, expiry);

        (bytes32 coreA,) = this.doComputeEntityHash(key, alice, current, alice, current, opA.expiresAt, opA);
        (bytes32 coreB,) = this.doComputeEntityHash(key, alice, current, alice, current, opB.expiresAt, opB);

        assertNotEq(coreA, coreB);
    }
}
