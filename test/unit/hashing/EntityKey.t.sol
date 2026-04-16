// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Entity} from "../../../src/Entity.sol";

contract EntityKeyTest is Test {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address registry = makeAddr("registry");
    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_entityKey_deterministic() public view {
        // GIVEN the same inputs
        // WHEN computing entityKey twice
        bytes32 keyA = Entity.entityKey(block.chainid, registry, alice, 0);
        bytes32 keyB = Entity.entityKey(block.chainid, registry, alice, 0);

        // THEN the keys are equal
        assertEq(keyA, keyB);
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different keys
    // -------------------------------------------------------------------------

    function test_entityKey_differentOwner_differs() public view {
        // GIVEN two different owners with the same nonce
        bytes32 keyA = Entity.entityKey(block.chainid, registry, alice, 0);
        bytes32 keyB = Entity.entityKey(block.chainid, registry, bob, 0);

        // THEN the keys differ
        assertNotEq(keyA, keyB);
    }

    function test_entityKey_differentNonce_differs() public view {
        // GIVEN the same owner with different nonces
        bytes32 keyA = Entity.entityKey(block.chainid, registry, alice, 0);
        bytes32 keyB = Entity.entityKey(block.chainid, registry, alice, 1);

        // THEN the keys differ
        assertNotEq(keyA, keyB);
    }

    function test_entityKey_differentChainId_differs() public view {
        // GIVEN two different chain IDs
        bytes32 keyA = Entity.entityKey(1, address(0xBEEF), alice, 0);
        bytes32 keyB = Entity.entityKey(999, address(0xBEEF), alice, 0);

        // THEN the keys differ
        assertNotEq(keyA, keyB);
    }

    function test_entityKey_differentRegistry_differs() public view {
        // GIVEN two different registry addresses
        bytes32 keyA = Entity.entityKey(1, address(0xAAA), alice, 0);
        bytes32 keyB = Entity.entityKey(1, address(0xBBB), alice, 0);

        // THEN the keys differ
        assertNotEq(keyA, keyB);
    }

    // -------------------------------------------------------------------------
    // EIP-712 structure — manual encoding match
    // -------------------------------------------------------------------------

    function test_entityKey_matchesManualComputation() public view {
        // GIVEN known inputs
        // WHEN computing manually
        bytes32 expected = keccak256(abi.encodePacked(block.chainid, registry, alice, uint32(0)));

        // THEN it matches the library
        assertEq(Entity.entityKey(block.chainid, registry, alice, 0), expected);
    }

    // -------------------------------------------------------------------------
    // Assembly correctness — fuzz against pure-Solidity reference
    // -------------------------------------------------------------------------

    function test_entityKey_fuzz(uint256 chainId, address registryAddr, address owner, uint32 nonce) public pure {
        // GIVEN arbitrary inputs
        // WHEN computing via the assembly implementation
        bytes32 actual = Entity.entityKey(chainId, registryAddr, owner, nonce);

        // THEN it matches the pure-Solidity reference
        bytes32 expected = keccak256(abi.encodePacked(chainId, registryAddr, owner, nonce));
        assertEq(actual, expected);
    }
}
