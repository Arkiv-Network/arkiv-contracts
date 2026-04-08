// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../utils/Base.t.sol";
import {Lib} from "../utils/Lib.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";

contract AttributeHashTest is Base {
    // -------------------------------------------------------------------------
    // Determinism — identical inputs produce identical hashes
    // -------------------------------------------------------------------------

    function test_attributeHash_uint_deterministic() public {
        // GIVEN the same UINT attribute constructed twice
        EntityHashing.Attribute memory a = Lib.uintAttr("count", 42);
        EntityHashing.Attribute memory b = Lib.uintAttr("count", 42);

        // WHEN hashing both
        // THEN the hashes are equal
        assertEq(registry.exposed_attributeHash(a), registry.exposed_attributeHash(b));
    }

    function test_attributeHash_string_deterministic() public {
        // GIVEN the same STRING attribute constructed twice
        EntityHashing.Attribute memory a = Lib.stringAttr("label", "hello");
        EntityHashing.Attribute memory b = Lib.stringAttr("label", "hello");

        // WHEN hashing both
        // THEN the hashes are equal
        assertEq(registry.exposed_attributeHash(a), registry.exposed_attributeHash(b));
    }

    function test_attributeHash_entityKey_deterministic() public {
        // GIVEN the same ENTITY_KEY attribute constructed twice
        bytes32 ref = keccak256("some-entity");
        EntityHashing.Attribute memory a = Lib.entityKeyAttr("parent", ref);
        EntityHashing.Attribute memory b = Lib.entityKeyAttr("parent", ref);

        // WHEN hashing both
        // THEN the hashes are equal
        assertEq(registry.exposed_attributeHash(a), registry.exposed_attributeHash(b));
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_attributeHash_differentName_differs() public {
        // GIVEN two UINT attributes with different names but same value
        EntityHashing.Attribute memory a = Lib.uintAttr("aaa", 1);
        EntityHashing.Attribute memory b = Lib.uintAttr("bbb", 1);

        // WHEN hashing both
        // THEN the hashes differ
        assertNotEq(registry.exposed_attributeHash(a), registry.exposed_attributeHash(b));
    }

    function test_attributeHash_differentValue_differs() public {
        // GIVEN two UINT attributes with same name but different values
        EntityHashing.Attribute memory a = Lib.uintAttr("count", 1);
        EntityHashing.Attribute memory b = Lib.uintAttr("count", 2);

        // WHEN hashing both
        // THEN the hashes differ
        assertNotEq(registry.exposed_attributeHash(a), registry.exposed_attributeHash(b));
    }

    function test_attributeHash_differentType_differs() public {
        // GIVEN a UINT and an ENTITY_KEY attribute with the same name and fixedValue
        EntityHashing.Attribute memory a = Lib.uintAttr("ref", 1);
        EntityHashing.Attribute memory b = Lib.entityKeyAttr("ref", bytes32(uint256(1)));

        // WHEN hashing both
        // THEN the hashes differ (valueType is part of the hash)
        assertNotEq(registry.exposed_attributeHash(a), registry.exposed_attributeHash(b));
    }

    function test_attributeHash_differentStringValue_differs() public {
        // GIVEN two STRING attributes with same name but different values
        EntityHashing.Attribute memory a = Lib.stringAttr("label", "foo");
        EntityHashing.Attribute memory b = Lib.stringAttr("label", "bar");

        // WHEN hashing both
        // THEN the hashes differ
        assertNotEq(registry.exposed_attributeHash(a), registry.exposed_attributeHash(b));
    }

    // -------------------------------------------------------------------------
    // Cross-type collision resistance
    // -------------------------------------------------------------------------

    function test_attributeHash_stringVsUint_sameNameZeroValues_differs() public {
        // GIVEN a STRING attr (fixedValue=0, stringValue="") and a UINT attr (fixedValue=0)
        // with the same name — they differ only in valueType
        EntityHashing.Attribute memory strAttr = Lib.stringAttr("tag", "");
        EntityHashing.Attribute memory uintAttr = Lib.uintAttr("tag", 0);

        // WHEN hashing both
        // THEN the hashes differ (valueType discriminates)
        assertNotEq(registry.exposed_attributeHash(strAttr), registry.exposed_attributeHash(uintAttr));
    }

    // -------------------------------------------------------------------------
    // EIP-712 structure — manual encoding match
    // -------------------------------------------------------------------------

    function test_attributeHash_uint_matchesManualEIP712Encoding() public {
        // GIVEN a UINT attribute
        EntityHashing.Attribute memory attr = Lib.uintAttr("count", 42);

        // WHEN computing the hash manually per EIP-712
        bytes32 expected = keccak256(
            abi.encode(
                EntityHashing.ATTRIBUTE_TYPEHASH,
                attr.name,
                attr.valueType,
                attr.fixedValue,
                keccak256(bytes(attr.stringValue))
            )
        );

        // THEN it matches the library's computation
        assertEq(registry.exposed_attributeHash(attr), expected);
    }

    function test_attributeHash_string_matchesManualEIP712Encoding() public {
        // GIVEN a STRING attribute
        EntityHashing.Attribute memory attr = Lib.stringAttr("label", "hello world");

        // WHEN computing the hash manually per EIP-712
        bytes32 expected = keccak256(
            abi.encode(
                EntityHashing.ATTRIBUTE_TYPEHASH,
                attr.name,
                attr.valueType,
                attr.fixedValue,
                keccak256(bytes(attr.stringValue))
            )
        );

        // THEN it matches the library's computation
        assertEq(registry.exposed_attributeHash(attr), expected);
    }

    function test_attributeHash_entityKey_matchesManualEIP712Encoding() public {
        // GIVEN an ENTITY_KEY attribute
        bytes32 ref = keccak256("some-entity");
        EntityHashing.Attribute memory attr = Lib.entityKeyAttr("parent", ref);

        // WHEN computing the hash manually per EIP-712
        bytes32 expected = keccak256(
            abi.encode(
                EntityHashing.ATTRIBUTE_TYPEHASH,
                attr.name,
                attr.valueType,
                attr.fixedValue,
                keccak256(bytes(attr.stringValue))
            )
        );

        // THEN it matches the library's computation
        assertEq(registry.exposed_attributeHash(attr), expected);
    }
}
