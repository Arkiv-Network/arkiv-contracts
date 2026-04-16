// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber} from "../../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Entity} from "../../../src/Entity.sol";

contract EntityStructHashTest is Test {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_entityStructHash_deterministic() public view {
        // GIVEN the same inputs
        bytes32 core = keccak256("core");

        // WHEN computing entityStructHash twice
        bytes32 hashA = Entity.entityStructHash(core, alice, BlockNumber.wrap(100), BlockNumber.wrap(200));
        bytes32 hashB = Entity.entityStructHash(core, alice, BlockNumber.wrap(100), BlockNumber.wrap(200));

        // THEN the hashes are equal
        assertEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_entityStructHash_differentCoreHash_differs() public view {
        // GIVEN two calls differing only in coreHash
        bytes32 hashA = Entity.entityStructHash(keccak256("core1"), alice, BlockNumber.wrap(100), BlockNumber.wrap(200));
        bytes32 hashB = Entity.entityStructHash(keccak256("core2"), alice, BlockNumber.wrap(100), BlockNumber.wrap(200));

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_entityStructHash_differentOwner_differs() public view {
        // GIVEN two calls differing only in owner
        bytes32 core = keccak256("core");

        bytes32 hashA = Entity.entityStructHash(core, alice, BlockNumber.wrap(100), BlockNumber.wrap(200));
        bytes32 hashB = Entity.entityStructHash(core, bob, BlockNumber.wrap(100), BlockNumber.wrap(200));

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_entityStructHash_differentUpdatedAt_differs() public view {
        // GIVEN two calls differing only in updatedAt
        bytes32 core = keccak256("core");

        bytes32 hashA = Entity.entityStructHash(core, alice, BlockNumber.wrap(100), BlockNumber.wrap(200));
        bytes32 hashB = Entity.entityStructHash(core, alice, BlockNumber.wrap(150), BlockNumber.wrap(200));

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_entityStructHash_differentExpiresAt_differs() public view {
        // GIVEN two calls differing only in expiresAt
        bytes32 core = keccak256("core");

        bytes32 hashA = Entity.entityStructHash(core, alice, BlockNumber.wrap(100), BlockNumber.wrap(200));
        bytes32 hashB = Entity.entityStructHash(core, alice, BlockNumber.wrap(100), BlockNumber.wrap(300));

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // EIP-712 structure — manual encoding match
    // -------------------------------------------------------------------------

    function test_entityStructHash_matchesManualEIP712Encoding() public view {
        // GIVEN inputs
        bytes32 core = keccak256("core");
        BlockNumber updatedAt = BlockNumber.wrap(100);
        BlockNumber expiresAt = BlockNumber.wrap(200);

        // WHEN computing manually per EIP-712
        bytes32 expected = keccak256(abi.encode(Entity.ENTITY_HASH_TYPEHASH, core, alice, updatedAt, expiresAt));

        // THEN it matches the library's computation
        assertEq(Entity.entityStructHash(core, alice, updatedAt, expiresAt), expected);
    }

    // -------------------------------------------------------------------------
    // Two-part structure property — coreHash stable across mutable fields
    // -------------------------------------------------------------------------

    function test_entityStructHash_coreHashStableAcrossOwnerChange() public view {
        // GIVEN the same coreHash
        bytes32 core = keccak256("core");

        // WHEN computing entityStructHash with different owners
        bytes32 hashAlice = Entity.entityStructHash(core, alice, BlockNumber.wrap(100), BlockNumber.wrap(200));
        bytes32 hashBob = Entity.entityStructHash(core, bob, BlockNumber.wrap(100), BlockNumber.wrap(200));

        // THEN the struct hashes differ (owner is in the outer hash)
        assertNotEq(hashAlice, hashBob);
    }

    function test_entityStructHash_coreHashStableAcrossExpiryExtension() public view {
        // GIVEN the same coreHash
        bytes32 core = keccak256("core");

        // WHEN computing entityStructHash with different expiry (simulating extend)
        bytes32 hashOriginal = Entity.entityStructHash(core, alice, BlockNumber.wrap(100), BlockNumber.wrap(200));
        bytes32 hashExtended = Entity.entityStructHash(core, alice, BlockNumber.wrap(150), BlockNumber.wrap(300));

        // THEN the struct hashes differ
        assertNotEq(hashOriginal, hashExtended);
    }

    // -------------------------------------------------------------------------
    // Assembly correctness — fuzz against pure-Solidity reference
    // -------------------------------------------------------------------------

    function test_entityStructHash_fuzz(bytes32 coreHash_, address owner, uint32 rawUpdatedAt, uint32 rawExpiresAt)
        public
        pure
    {
        // GIVEN arbitrary inputs
        BlockNumber updatedAt = BlockNumber.wrap(rawUpdatedAt);
        BlockNumber expiresAt = BlockNumber.wrap(rawExpiresAt);

        // WHEN computing via the assembly implementation
        bytes32 actual = Entity.entityStructHash(coreHash_, owner, updatedAt, expiresAt);

        // THEN it matches the pure-Solidity reference
        bytes32 expected = keccak256(abi.encode(Entity.ENTITY_HASH_TYPEHASH, coreHash_, owner, updatedAt, expiresAt));
        assertEq(actual, expected);
    }
}
