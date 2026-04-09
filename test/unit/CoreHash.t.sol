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
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = Lib.uintAttr("count", 1);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);

        assertEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_coreHash_differentKey_differs() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA =
            registry.exposed_coreHash(keccak256("key1"), alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB =
            registry.exposed_coreHash(keccak256("key2"), alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentCreator_differs() public {
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB = registry.exposed_coreHash(key, bob, BlockNumber.wrap(100), "text/plain", "hello", attrs);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentCreatedAt_differs() public {
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(200), "text/plain", "hello", attrs);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentContentType_differs() public {
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "application/json", "hello", attrs);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentPayload_differs() public {
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "world", attrs);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentAttributes_differs() public {
        bytes32 key = keccak256("key");

        EntityHashing.Attribute[] memory attrsA = new EntityHashing.Attribute[](1);
        attrsA[0] = Lib.uintAttr("count", 1);

        EntityHashing.Attribute[] memory attrsB = new EntityHashing.Attribute[](1);
        attrsB[0] = Lib.uintAttr("count", 2);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrsA);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrsB);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_emptyVsNonEmptyAttributes_differs() public {
        bytes32 key = keccak256("key");

        EntityHashing.Attribute[] memory empty = new EntityHashing.Attribute[](0);
        EntityHashing.Attribute[] memory one = new EntityHashing.Attribute[](1);
        one[0] = Lib.uintAttr("count", 1);

        bytes32 hashA = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", empty);
        bytes32 hashB = registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", one);

        assertNotEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Attribute order — unsorted reverts
    // -------------------------------------------------------------------------

    function test_coreHash_unsortedAttributes_reverts() public {
        bytes32 key = keccak256("key");

        // "bbb" > "aaa" lexicographically, so [bbb, aaa] is wrong order
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = Lib.uintAttr("bbb", 2);
        attrs[1] = Lib.uintAttr("aaa", 1);

        vm.expectRevert(EntityHashing.AttributesNotSorted.selector);
        registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "hello", attrs);
    }

    // -------------------------------------------------------------------------
    // EIP-712 structure — manual encoding match
    // -------------------------------------------------------------------------

    function test_coreHash_matchesManualEIP712Encoding() public {
        bytes32 key = keccak256("key");
        BlockNumber createdAt = BlockNumber.wrap(100);
        bytes memory payload = "hello";
        string memory contentType = "text/plain";

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = Lib.uintAttr("aaa", 10);
        attrs[1] = Lib.stringAttr("bbb", "val");

        // Compute rolling attribute chain manually
        bytes32 hashA = keccak256(
            abi.encode(EntityHashing.ATTRIBUTE_TYPEHASH, attrs[0].name, attrs[0].valueType, keccak256(attrs[0].value))
        );
        bytes32 hashB = keccak256(
            abi.encode(EntityHashing.ATTRIBUTE_TYPEHASH, attrs[1].name, attrs[1].valueType, keccak256(attrs[1].value))
        );
        bytes32 attrChain = keccak256(abi.encodePacked(bytes32(0), hashA));
        attrChain = keccak256(abi.encodePacked(attrChain, hashB));

        bytes32 expected = keccak256(
            abi.encode(
                EntityHashing.CORE_HASH_TYPEHASH,
                key,
                alice,
                createdAt,
                keccak256(bytes(contentType)),
                keccak256(payload),
                attrChain
            )
        );

        assertEq(registry.exposed_coreHash(key, alice, createdAt, contentType, payload, attrs), expected);
    }

    function test_coreHash_emptyPayloadAndAttributes() public {
        bytes32 key = keccak256("key");

        // Empty attributes → rolling chain = bytes32(0)
        bytes32 expected = keccak256(
            abi.encode(
                EntityHashing.CORE_HASH_TYPEHASH,
                key,
                alice,
                BlockNumber.wrap(100),
                keccak256(bytes("text/plain")),
                keccak256(""),
                bytes32(0)
            )
        );

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        assertEq(registry.exposed_coreHash(key, alice, BlockNumber.wrap(100), "text/plain", "", attrs), expected);
    }

    // -------------------------------------------------------------------------
    // Fuzz — verify encoding consistency
    // -------------------------------------------------------------------------

    function test_coreHash_fuzz(
        bytes32 key,
        address creator,
        uint32 rawCreatedAt,
        string calldata contentType,
        bytes calldata payload
    ) public {
        BlockNumber createdAt = BlockNumber.wrap(rawCreatedAt);
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 actual = registry.exposed_coreHash(key, creator, createdAt, contentType, payload, attrs);

        // Empty attributes → attrChain = bytes32(0)
        bytes32 expected = keccak256(
            abi.encode(
                EntityHashing.CORE_HASH_TYPEHASH,
                key,
                creator,
                createdAt,
                keccak256(bytes(contentType)),
                keccak256(payload),
                bytes32(0)
            )
        );
        assertEq(actual, expected);
    }
}
