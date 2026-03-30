// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EntityRegistryBase} from "./EntityRegistryBase.t.sol";
import {EntityRegistry} from "../src/EntityRegistry.sol";

contract EntityRegistryHashTest is EntityRegistryBase {
    using ShortStrings for *;

    // -------------------------------------------------------------------------
    // attributeHash — determinism
    // -------------------------------------------------------------------------

    function test_attributeHash_uint_deterministic() public view {
        // GIVEN the same UINT attribute constructed twice
        EntityRegistry.Attribute memory a = _uintAttr("count", 42);
        EntityRegistry.Attribute memory b = _uintAttr("count", 42);

        // WHEN hashing both
        bytes32 hashA = registry.attributeHash(a);
        bytes32 hashB = registry.attributeHash(b);

        // THEN the hashes are equal
        assertEq(hashA, hashB);
    }

    function test_attributeHash_string_deterministic() public view {
        // GIVEN the same STRING attribute constructed twice
        EntityRegistry.Attribute memory a = _stringAttr("label", "hello");
        EntityRegistry.Attribute memory b = _stringAttr("label", "hello");

        // WHEN hashing both
        bytes32 hashA = registry.attributeHash(a);
        bytes32 hashB = registry.attributeHash(b);

        // THEN the hashes are equal
        assertEq(hashA, hashB);
    }

    function test_attributeHash_entityKey_deterministic() public view {
        // GIVEN the same ENTITY_KEY attribute constructed twice
        bytes32 ref = keccak256("some-entity");
        EntityRegistry.Attribute memory a = _entityKeyAttr("parent", ref);
        EntityRegistry.Attribute memory b = _entityKeyAttr("parent", ref);

        // WHEN hashing both
        bytes32 hashA = registry.attributeHash(a);
        bytes32 hashB = registry.attributeHash(b);

        // THEN the hashes are equal
        assertEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // attributeHash — different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_attributeHash_differentName_differs() public view {
        // GIVEN two UINT attributes with different names but same value
        EntityRegistry.Attribute memory a = _uintAttr("aaa", 1);
        EntityRegistry.Attribute memory b = _uintAttr("bbb", 1);

        // WHEN hashing both
        // THEN the hashes differ
        assertNotEq(registry.attributeHash(a), registry.attributeHash(b));
    }

    function test_attributeHash_differentValue_differs() public view {
        // GIVEN two UINT attributes with same name but different values
        EntityRegistry.Attribute memory a = _uintAttr("count", 1);
        EntityRegistry.Attribute memory b = _uintAttr("count", 2);

        // WHEN hashing both
        // THEN the hashes differ
        assertNotEq(registry.attributeHash(a), registry.attributeHash(b));
    }

    function test_attributeHash_differentType_differs() public view {
        // GIVEN a UINT and an ENTITY_KEY attribute with the same name and fixedValue
        EntityRegistry.Attribute memory a = _uintAttr("ref", 1);
        EntityRegistry.Attribute memory b = _entityKeyAttr("ref", bytes32(uint256(1)));

        // WHEN hashing both
        // THEN the hashes differ (valueType is part of the hash)
        assertNotEq(registry.attributeHash(a), registry.attributeHash(b));
    }

    function test_attributeHash_differentStringValue_differs() public view {
        // GIVEN two STRING attributes with same name but different values
        EntityRegistry.Attribute memory a = _stringAttr("label", "foo");
        EntityRegistry.Attribute memory b = _stringAttr("label", "bar");

        // WHEN hashing both
        // THEN the hashes differ
        assertNotEq(registry.attributeHash(a), registry.attributeHash(b));
    }

    // -------------------------------------------------------------------------
    // attributeHash — EIP-712 structure
    // -------------------------------------------------------------------------

    function test_attributeHash_matchesManualEIP712Encoding() public view {
        // GIVEN a UINT attribute
        EntityRegistry.Attribute memory attr = _uintAttr("count", 42);

        // WHEN computing the hash manually per EIP-712
        bytes32 expected = keccak256(
            abi.encode(
                registry.ATTRIBUTE_TYPEHASH(),
                attr.name,
                attr.valueType,
                attr.fixedValue,
                keccak256(bytes(attr.stringValue))
            )
        );

        // THEN it matches the contract's computation
        assertEq(registry.attributeHash(attr), expected);
    }

    function test_attributeHash_stringAttr_matchesManualEIP712Encoding() public view {
        // GIVEN a STRING attribute
        EntityRegistry.Attribute memory attr = _stringAttr("label", "hello world");

        // WHEN computing the hash manually per EIP-712
        bytes32 expected = keccak256(
            abi.encode(
                registry.ATTRIBUTE_TYPEHASH(),
                attr.name,
                attr.valueType,
                attr.fixedValue,
                keccak256(bytes(attr.stringValue))
            )
        );

        // THEN it matches the contract's computation
        assertEq(registry.attributeHash(attr), expected);
    }

    // -------------------------------------------------------------------------
    // coreHash — determinism
    // -------------------------------------------------------------------------

    function test_coreHash_deterministic() public view {
        // GIVEN identical inputs
        bytes32 key = keccak256("key");
        uint32 createdAt = 100;
        bytes memory payload = "hello";
        string memory contentType = "text/plain";
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](1);
        attrs[0] = _uintAttr("count", 1);

        // WHEN computing coreHash twice with the same inputs
        bytes32 hashA = registry.coreHash(key, alice, createdAt, contentType, payload, attrs);
        bytes32 hashB = registry.coreHash(key, alice, createdAt, contentType, payload, attrs);

        // THEN the hashes are equal
        assertEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // coreHash — different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_coreHash_differentKey_differs() public view {
        // GIVEN two calls differing only in key
        bytes memory payload = "hello";
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);

        bytes32 hashA = registry.coreHash(keccak256("key1"), alice, 100, "text/plain", payload, attrs);
        bytes32 hashB = registry.coreHash(keccak256("key2"), alice, 100, "text/plain", payload, attrs);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentCreator_differs() public view {
        // GIVEN two calls differing only in creator
        bytes32 key = keccak256("key");
        bytes memory payload = "hello";
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);

        bytes32 hashA = registry.coreHash(key, alice, 100, "text/plain", payload, attrs);
        bytes32 hashB = registry.coreHash(key, bob, 100, "text/plain", payload, attrs);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentCreatedAt_differs() public view {
        // GIVEN two calls differing only in createdAt
        bytes32 key = keccak256("key");
        bytes memory payload = "hello";
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);

        bytes32 hashA = registry.coreHash(key, alice, 100, "text/plain", payload, attrs);
        bytes32 hashB = registry.coreHash(key, alice, 200, "text/plain", payload, attrs);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentContentType_differs() public view {
        // GIVEN two calls differing only in contentType
        bytes32 key = keccak256("key");
        bytes memory payload = "hello";
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);

        bytes32 hashA = registry.coreHash(key, alice, 100, "text/plain", payload, attrs);
        bytes32 hashB = registry.coreHash(key, alice, 100, "application/json", payload, attrs);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentPayload_differs() public view {
        // GIVEN two calls differing only in payload
        bytes32 key = keccak256("key");
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);

        bytes32 hashA = registry.coreHash(key, alice, 100, "text/plain", "hello", attrs);
        bytes32 hashB = registry.coreHash(key, alice, 100, "text/plain", "world", attrs);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentAttributes_differs() public view {
        // GIVEN two calls differing only in attributes
        bytes32 key = keccak256("key");
        bytes memory payload = "hello";

        EntityRegistry.Attribute[] memory attrsA = new EntityRegistry.Attribute[](1);
        attrsA[0] = _uintAttr("count", 1);

        EntityRegistry.Attribute[] memory attrsB = new EntityRegistry.Attribute[](1);
        attrsB[0] = _uintAttr("count", 2);

        bytes32 hashA = registry.coreHash(key, alice, 100, "text/plain", payload, attrsA);
        bytes32 hashB = registry.coreHash(key, alice, 100, "text/plain", payload, attrsB);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_coreHash_emptyVsNonEmptyAttributes_differs() public view {
        // GIVEN one call with no attributes and one with attributes
        bytes32 key = keccak256("key");
        bytes memory payload = "hello";

        EntityRegistry.Attribute[] memory empty = new EntityRegistry.Attribute[](0);
        EntityRegistry.Attribute[] memory one = new EntityRegistry.Attribute[](1);
        one[0] = _uintAttr("count", 1);

        bytes32 hashA = registry.coreHash(key, alice, 100, "text/plain", payload, empty);
        bytes32 hashB = registry.coreHash(key, alice, 100, "text/plain", payload, one);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // coreHash — EIP-712 structure
    // -------------------------------------------------------------------------

    function test_coreHash_matchesManualEIP712Encoding() public view {
        // GIVEN inputs with two attributes
        bytes32 key = keccak256("key");
        uint32 createdAt = 100;
        bytes memory payload = "hello";
        string memory contentType = "text/plain";

        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](2);
        attrs[0] = _uintAttr("aaa", 10);
        attrs[1] = _stringAttr("bbb", "val");

        // WHEN computing manually per EIP-712
        bytes32[] memory attrHashes = new bytes32[](2);
        attrHashes[0] = registry.attributeHash(attrs[0]);
        attrHashes[1] = registry.attributeHash(attrs[1]);

        bytes32 expected = keccak256(
            abi.encode(
                registry.CORE_HASH_TYPEHASH(),
                key,
                alice,
                createdAt,
                keccak256(bytes(contentType)),
                keccak256(payload),
                keccak256(abi.encodePacked(attrHashes))
            )
        );

        // THEN it matches the contract's computation
        assertEq(registry.coreHash(key, alice, createdAt, contentType, payload, attrs), expected);
    }

    function test_coreHash_emptyPayloadAndAttributes() public view {
        // GIVEN empty payload and no attributes
        bytes32 key = keccak256("key");
        bytes memory payload = "";
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);

        // WHEN computing manually
        bytes32[] memory attrHashes = new bytes32[](0);
        bytes32 expected = keccak256(
            abi.encode(
                registry.CORE_HASH_TYPEHASH(),
                key,
                alice,
                uint32(100),
                keccak256(bytes("text/plain")),
                keccak256(payload),
                keccak256(abi.encodePacked(attrHashes))
            )
        );

        // THEN it matches the contract
        assertEq(registry.coreHash(key, alice, 100, "text/plain", payload, attrs), expected);
    }

    // -------------------------------------------------------------------------
    // entityHash — determinism
    // -------------------------------------------------------------------------

    function test_entityHash_deterministic() public view {
        // GIVEN the same inputs
        bytes32 core = keccak256("core");

        // WHEN computing entityHash twice
        bytes32 hashA = registry.entityHash(core, alice, 100, 200);
        bytes32 hashB = registry.entityHash(core, alice, 100, 200);

        // THEN the hashes are equal
        assertEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // entityHash — different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_entityHash_differentCoreHash_differs() public view {
        // GIVEN two calls differing only in coreHash
        bytes32 hashA = registry.entityHash(keccak256("core1"), alice, 100, 200);
        bytes32 hashB = registry.entityHash(keccak256("core2"), alice, 100, 200);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_entityHash_differentOwner_differs() public view {
        // GIVEN two calls differing only in owner
        bytes32 core = keccak256("core");

        bytes32 hashA = registry.entityHash(core, alice, 100, 200);
        bytes32 hashB = registry.entityHash(core, bob, 100, 200);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_entityHash_differentUpdatedAt_differs() public view {
        // GIVEN two calls differing only in updatedAt
        bytes32 core = keccak256("core");

        bytes32 hashA = registry.entityHash(core, alice, 100, 200);
        bytes32 hashB = registry.entityHash(core, alice, 150, 200);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_entityHash_differentExpiresAt_differs() public view {
        // GIVEN two calls differing only in expiresAt
        bytes32 core = keccak256("core");

        bytes32 hashA = registry.entityHash(core, alice, 100, 200);
        bytes32 hashB = registry.entityHash(core, alice, 100, 300);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // entityHash — EIP-712 structure (includes domain separator)
    // -------------------------------------------------------------------------

    function test_entityHash_matchesManualEIP712Encoding() public view {
        // GIVEN inputs
        bytes32 core = keccak256("core");
        uint32 updatedAt = 100;
        uint32 expiresAt = 200;

        // WHEN computing manually with the domain separator
        bytes32 domainSeparator = _domainSeparator();
        bytes32 structHash = keccak256(abi.encode(registry.ENTITY_HASH_TYPEHASH(), core, alice, updatedAt, expiresAt));
        bytes32 expected = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // THEN it matches the contract's computation
        assertEq(registry.entityHash(core, alice, updatedAt, expiresAt), expected);
    }

    // -------------------------------------------------------------------------
    // entityHash — two-part structure property
    // -------------------------------------------------------------------------

    function test_entityHash_coreHashStableAcrossOwnerChange() public view {
        // GIVEN a coreHash computed from entity content
        bytes32 key = keccak256("key");
        bytes memory payload = "hello";
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](1);
        attrs[0] = _uintAttr("count", 1);

        bytes32 core = registry.coreHash(key, alice, 100, "text/plain", payload, attrs);

        // WHEN computing entityHash with different owners
        bytes32 hashAlice = registry.entityHash(core, alice, 100, 200);
        bytes32 hashBob = registry.entityHash(core, bob, 100, 200);

        // THEN the entityHashes differ (owner is in the outer hash)
        assertNotEq(hashAlice, hashBob);

        // AND the coreHash is the same for both (can be reused without recomputation)
        // This is the key property: changeOwner only needs coreHash from chain state,
        // not the full payload/attributes.
        bytes32 coreAgain = registry.coreHash(key, alice, 100, "text/plain", payload, attrs);
        assertEq(core, coreAgain);
    }

    function test_entityHash_coreHashStableAcrossExpiryExtension() public view {
        // GIVEN a coreHash computed from entity content
        bytes32 key = keccak256("key");
        bytes memory payload = "hello";
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);

        bytes32 core = registry.coreHash(key, alice, 100, "text/plain", payload, attrs);

        // WHEN computing entityHash with different expiresAt (simulating extendEntity)
        bytes32 hashOriginal = registry.entityHash(core, alice, 100, 200);
        bytes32 hashExtended = registry.entityHash(core, alice, 150, 300);

        // THEN the entityHashes differ
        assertNotEq(hashOriginal, hashExtended);

        // AND the coreHash is unchanged — extendEntity doesn't need the payload
        bytes32 coreAgain = registry.coreHash(key, alice, 100, "text/plain", payload, attrs);
        assertEq(core, coreAgain);
    }

    // -------------------------------------------------------------------------
    // entityKey
    // -------------------------------------------------------------------------

    function test_entityKey_deterministic() public view {
        // GIVEN the same owner and nonce
        // WHEN computing entityKey twice
        bytes32 keyA = registry.entityKey(alice, 0);
        bytes32 keyB = registry.entityKey(alice, 0);

        // THEN the keys are equal
        assertEq(keyA, keyB);
    }

    function test_entityKey_differentOwner_differs() public view {
        // GIVEN two different owners with the same nonce
        bytes32 keyA = registry.entityKey(alice, 0);
        bytes32 keyB = registry.entityKey(bob, 0);

        // THEN the keys differ
        assertNotEq(keyA, keyB);
    }

    function test_entityKey_differentNonce_differs() public view {
        // GIVEN the same owner with different nonces
        bytes32 keyA = registry.entityKey(alice, 0);
        bytes32 keyB = registry.entityKey(alice, 1);

        // THEN the keys differ
        assertNotEq(keyA, keyB);
    }

    function test_entityKey_matchesManualComputation() public view {
        // GIVEN known inputs
        // WHEN computing manually
        bytes32 expected = keccak256(abi.encodePacked(block.chainid, address(registry), alice, uint32(0)));

        // THEN it matches the contract
        assertEq(registry.entityKey(alice, 0), expected);
    }

    function test_entityKey_includesContractAddress() public {
        // GIVEN two registry deployments
        EntityRegistry registry2 = new EntityRegistry();

        // WHEN computing entityKey for the same owner and nonce on each
        bytes32 key1 = registry.entityKey(alice, 0);
        bytes32 key2 = registry2.entityKey(alice, 0);

        // THEN the keys differ (contract address is part of the hash)
        assertNotEq(key1, key2);
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _domainSeparator() internal view returns (bytes32) {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            registry.eip712Domain();
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes(version)),
                chainId,
                verifyingContract
            )
        );
    }
}
