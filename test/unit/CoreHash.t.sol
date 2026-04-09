// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../src/BlockNumber.sol";
import {Base} from "../utils/Base.t.sol";
import {Lib} from "../utils/Lib.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";

contract CoreHashTest is Base {
    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_coreHash_deterministic() public {
        // GIVEN identical inputs
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = Lib.uintAttr("count", 1);

        // WHEN computing coreHash twice with the same inputs
        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);

        // THEN the hashes are equal
        assertEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_coreHash_differentKey_differs() public {
        // GIVEN two calls differing only in key
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA =
            registry.exposed_coreHash(keccak256("key1"), alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB =
            registry.exposed_coreHash(keccak256("key2"), alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentCreator_differs() public {
        // GIVEN two calls differing only in creator
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB = registry.exposed_coreHash(key, bob, BlockNumber.wrap(100), "text/plain", "hello", attrs);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentCreatedAt_differs() public {
        // GIVEN two calls differing only in createdAt
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(200), "text/plain", "hello", attrs);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentContentType_differs() public {
        // GIVEN two calls differing only in contentType
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "application/json", "hello", attrs);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentPayload_differs() public {
        // GIVEN two calls differing only in payload
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "world", attrs);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentAttributes_differs() public {
        // GIVEN two calls differing only in attribute values
        bytes32 key = keccak256("key");

        EntityHashing.Attribute[] memory attrsA = new EntityHashing.Attribute[](1);
        attrsA[0] = Lib.uintAttr("count", 1);

        EntityHashing.Attribute[] memory attrsB = new EntityHashing.Attribute[](1);
        attrsB[0] = Lib.uintAttr("count", 2);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrsA);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrsB);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_emptyVsNonEmptyAttributes_differs() public {
        // GIVEN one call with no attributes and one with attributes
        bytes32 key = keccak256("key");

        EntityHashing.Attribute[] memory empty = new EntityHashing.Attribute[](0);
        EntityHashing.Attribute[] memory one = new EntityHashing.Attribute[](1);
        one[0] = Lib.uintAttr("count", 1);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", empty);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", one);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Attribute order sensitivity
    // -------------------------------------------------------------------------

    function test_coreHash_attributeOrderMatters() public {
        // GIVEN two attribute arrays with the same elements in different order
        bytes32 key = keccak256("key");

        EntityHashing.Attribute[] memory attrsAB = new EntityHashing.Attribute[](2);
        attrsAB[0] = Lib.uintAttr("aaa", 1);
        attrsAB[1] = Lib.uintAttr("bbb", 2);

        EntityHashing.Attribute[] memory attrsBA = new EntityHashing.Attribute[](2);
        attrsBA[0] = Lib.uintAttr("bbb", 2);
        attrsBA[1] = Lib.uintAttr("aaa", 1);

        bytes32 hashAB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrsAB);
        bytes32 hashBA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrsBA);

        // THEN they differ — this is why the contract requires sorted attributes
        assertNotEq(hashAB, hashBA);
    }

    // -------------------------------------------------------------------------
    // EIP-712 structure — manual encoding match
    // -------------------------------------------------------------------------

    function test_coreHash_matchesManualEIP712Encoding() public {
        // GIVEN inputs with two attributes
        bytes32 key = keccak256("key");
        BlockNumber createdAt = BlockNumber.wrap(100);
        bytes memory payload = "hello";
        string memory contentType = "text/plain";

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = Lib.uintAttr("aaa", 10);
        attrs[1] = Lib.stringAttr("bbb", "val");

        // WHEN computing manually per EIP-712
        bytes32[] memory attrHashes = new bytes32[](2);
        attrHashes[0] = registry.exposed_attributeHash(attrs[0]);
        attrHashes[1] = registry.exposed_attributeHash(attrs[1]);

        bytes32 expected = keccak256(
            abi.encode(
                EntityHashing.CORE_HASH_TYPEHASH,
                key,
                alice,
                createdAt,
                keccak256(bytes(contentType)),
                keccak256(payload),
                keccak256(abi.encodePacked(attrHashes))
            )
        );

        // THEN it matches the library's computation
        assertEq(registry.exposed_coreHash(key, alice, createdAt, contentType, payload, attrs), expected);
    }

    function test_coreHash_emptyPayloadAndAttributes() public {
        // GIVEN empty payload and no attributes
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        // WHEN computing manually
        bytes32[] memory attrHashes = new bytes32[](0);
        bytes32 expected = keccak256(
            abi.encode(
                EntityHashing.CORE_HASH_TYPEHASH,
                key,
                alice,
                BlockNumber.wrap(100),
                keccak256(bytes("text/plain")),
                keccak256(""),
                keccak256(abi.encodePacked(attrHashes))
            )
        );

        // THEN it matches the library
        assertEq(registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "", attrs), expected);
    }

    // -------------------------------------------------------------------------
    // Assembly correctness — fuzz against pure-Solidity reference
    // -------------------------------------------------------------------------

    function test_coreHash_fuzz(
        bytes32 key,
        address creator,
        uint32 rawCreatedAt,
        string calldata contentType,
        bytes calldata payload
    ) public {
        // GIVEN arbitrary core inputs with no attributes
        BlockNumber createdAt = BlockNumber.wrap(rawCreatedAt);
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        // WHEN computing via the assembly implementation
        bytes32 actual = registry.exposed_coreHash(key, creator, createdAt, contentType, payload, attrs);

        // THEN it matches the pure-Solidity reference
        bytes32[] memory attrHashes = new bytes32[](0);
        bytes32 expected = keccak256(
            abi.encode(
                EntityHashing.CORE_HASH_TYPEHASH,
                key,
                creator,
                createdAt,
                keccak256(bytes(contentType)),
                keccak256(payload),
                keccak256(abi.encodePacked(attrHashes))
            )
        );
        assertEq(actual, expected);
    }
}
