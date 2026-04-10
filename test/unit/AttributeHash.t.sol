// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../utils/Base.t.sol";
import {Lib} from "../utils/Lib.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";

contract AttributeHashTest is Base {
    // -------------------------------------------------------------------------
    // Helper — hash a single attribute via the step function
    // -------------------------------------------------------------------------

    function _hashOne(EntityHashing.Attribute memory attr) internal view returns (bytes32) {
        (, bytes32 chain) = registry.exposed_attributeHash(bytes32(0), bytes32(0), attr);
        return chain;
    }

    // -------------------------------------------------------------------------
    // Determinism — identical inputs produce identical hashes
    // -------------------------------------------------------------------------

    function test_attributeHash_uint_deterministic() public view {
        assertEq(_hashOne(Lib.uintAttr("count", 42)), _hashOne(Lib.uintAttr("count", 42)));
    }

    function test_attributeHash_string_deterministic() public view {
        assertEq(_hashOne(Lib.stringAttr("label", "hello")), _hashOne(Lib.stringAttr("label", "hello")));
    }

    function test_attributeHash_entityKey_deterministic() public view {
        bytes32 ref = keccak256("some-entity");
        assertEq(_hashOne(Lib.entityKeyAttr("parent", ref)), _hashOne(Lib.entityKeyAttr("parent", ref)));
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_attributeHash_differentName_differs() public view {
        assertNotEq(_hashOne(Lib.uintAttr("aaa", 1)), _hashOne(Lib.uintAttr("bbb", 1)));
    }

    function test_attributeHash_differentValue_differs() public view {
        assertNotEq(_hashOne(Lib.uintAttr("count", 1)), _hashOne(Lib.uintAttr("count", 2)));
    }

    function test_attributeHash_differentType_differs() public view {
        assertNotEq(
            _hashOne(Lib.uintAttr("ref", 1)), _hashOne(Lib.entityKeyAttr("ref", bytes32(uint256(1))))
        );
    }

    function test_attributeHash_differentStringValue_differs() public view {
        assertNotEq(_hashOne(Lib.stringAttr("label", "foo")), _hashOne(Lib.stringAttr("label", "bar")));
    }

    // -------------------------------------------------------------------------
    // Cross-type collision resistance
    // -------------------------------------------------------------------------

    function test_attributeHash_stringVsUint_sameNameZeroValues_differs() public view {
        assertNotEq(_hashOne(Lib.stringAttr("tag", "")), _hashOne(Lib.uintAttr("tag", 0)));
    }

    // -------------------------------------------------------------------------
    // EIP-712 structure — manual encoding match
    // -------------------------------------------------------------------------

    function test_attributeHash_uint_matchesManualEIP712Encoding() public view {
        EntityHashing.Attribute memory attr = Lib.uintAttr("count", 42);

        bytes32 expected = keccak256(
            abi.encodePacked(
                bytes32(0),
                keccak256(
                    abi.encode(EntityHashing.ATTRIBUTE_TYPEHASH, attr.name, attr.valueType, keccak256(attr.value))
                )
            )
        );

        assertEq(_hashOne(attr), expected);
    }

    function test_attributeHash_string_matchesManualEIP712Encoding() public view {
        EntityHashing.Attribute memory attr = Lib.stringAttr("label", "hello world");

        bytes32 expected = keccak256(
            abi.encodePacked(
                bytes32(0),
                keccak256(
                    abi.encode(EntityHashing.ATTRIBUTE_TYPEHASH, attr.name, attr.valueType, keccak256(attr.value))
                )
            )
        );

        assertEq(_hashOne(attr), expected);
    }

    function test_attributeHash_entityKey_matchesManualEIP712Encoding() public view {
        bytes32 ref = keccak256("some-entity");
        EntityHashing.Attribute memory attr = Lib.entityKeyAttr("parent", ref);

        bytes32 expected = keccak256(
            abi.encodePacked(
                bytes32(0),
                keccak256(
                    abi.encode(EntityHashing.ATTRIBUTE_TYPEHASH, attr.name, attr.valueType, keccak256(attr.value))
                )
            )
        );

        assertEq(_hashOne(attr), expected);
    }

    // -------------------------------------------------------------------------
    // Rolling hash — attributesHash
    // -------------------------------------------------------------------------

    function test_attributesHash_empty_returnsZero() public view {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        assertEq(registry.exposed_attributesHash(attrs), bytes32(0));
    }

    function test_attributesHash_two_matchesManualChain() public view {
        // Lexicographic: "count" (0x636f...) < "label" (0x6c61...)
        EntityHashing.Attribute memory a = Lib.uintAttr("count", 42);
        EntityHashing.Attribute memory b = Lib.stringAttr("label", "hello");

        bytes32 hashA =
            keccak256(abi.encode(EntityHashing.ATTRIBUTE_TYPEHASH, a.name, a.valueType, keccak256(a.value)));
        bytes32 hashB =
            keccak256(abi.encode(EntityHashing.ATTRIBUTE_TYPEHASH, b.name, b.valueType, keccak256(b.value)));
        bytes32 chain = keccak256(abi.encodePacked(bytes32(0), hashA));
        chain = keccak256(abi.encodePacked(chain, hashB));

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = a;
        attrs[1] = b;
        assertEq(registry.exposed_attributesHash(attrs), chain);
    }

    // -------------------------------------------------------------------------
    // Sorting / uniqueness validation
    // -------------------------------------------------------------------------

    function test_attributesHash_revertsOnUnsortedNames() public {
        // "label" > "count" lexicographically, so [label, count] is wrong order
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = Lib.stringAttr("label", "hello");
        attrs[1] = Lib.uintAttr("count", 42);

        vm.expectRevert(EntityHashing.AttributesNotSorted.selector);
        registry.exposed_attributesHash(attrs);
    }

    function test_attributesHash_revertsOnDuplicateNames() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = Lib.uintAttr("count", 1);
        attrs[1] = Lib.uintAttr("count", 2);

        vm.expectRevert(EntityHashing.AttributesNotSorted.selector);
        registry.exposed_attributesHash(attrs);
    }
}
