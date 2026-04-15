// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../src/Entity.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {Ident32, IDENT_CHARSET, IDENT_LEADING} from "../../../src/types/Ident32.sol";

contract AttributeHashTest is Test, EntityRegistry {
    function doAttributeHash(Ident32 prevName, bytes32 chain, Entity.Attribute calldata attr)
        external
        pure
        returns (Ident32, bytes32)
    {
        return Entity.attributeHash(prevName, chain, attr);
    }

    function _hashOne(Entity.Attribute memory attr) internal view returns (bytes32) {
        (, bytes32 chain) = this.doAttributeHash(Ident32.wrap(bytes32(0)), bytes32(0), attr);
        return chain;
    }

    function _hashMany(Entity.Attribute[] memory attrs) internal view returns (bytes32) {
        bytes32 chain;
        Ident32 prevName;
        for (uint256 i = 0; i < attrs.length; i++) {
            (prevName, chain) = this.doAttributeHash(prevName, chain, attrs[i]);
        }
        return chain;
    }

    function _valueHash(bytes32[4] memory v) internal pure returns (bytes32) {
        return keccak256(abi.encode(v[0], v[1], v[2], v[3]));
    }

    // ---- Determinism ----

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

    // ---- Different inputs ----

    function test_attributeHash_differentName_differs() public view {
        assertNotEq(_hashOne(Lib.uintAttr("aaa", 1)), _hashOne(Lib.uintAttr("bbb", 1)));
    }

    function test_attributeHash_differentValue_differs() public view {
        assertNotEq(_hashOne(Lib.uintAttr("count", 1)), _hashOne(Lib.uintAttr("count", 2)));
    }

    function test_attributeHash_differentType_differs() public view {
        assertNotEq(_hashOne(Lib.uintAttr("ref", 1)), _hashOne(Lib.entityKeyAttr("ref", bytes32(uint256(1)))));
    }

    function test_attributeHash_differentStringValue_differs() public view {
        assertNotEq(_hashOne(Lib.stringAttr("label", "foo")), _hashOne(Lib.stringAttr("label", "bar")));
    }

    // ---- Cross-type collision resistance ----

    function test_attributeHash_stringVsUint_sameNameZeroValues_differs() public view {
        assertNotEq(_hashOne(Lib.stringAttr("tag", "")), _hashOne(Lib.uintAttr("tag", 0)));
    }

    // ---- Manual EIP-712 encoding match ----

    function test_attributeHash_uint_matchesManualEIP712Encoding() public view {
        Entity.Attribute memory attr = Lib.uintAttr("count", 42);
        bytes32 expected = keccak256(
            abi.encodePacked(
                bytes32(0),
                keccak256(
                    abi.encode(
                        Entity.ATTRIBUTE_TYPEHASH, Ident32.unwrap(attr.name), attr.valueType, _valueHash(attr.value)
                    )
                )
            )
        );
        assertEq(_hashOne(attr), expected);
    }

    function test_attributeHash_string_matchesManualEIP712Encoding() public view {
        Entity.Attribute memory attr = Lib.stringAttr("label", "hello world");
        bytes32 expected = keccak256(
            abi.encodePacked(
                bytes32(0),
                keccak256(
                    abi.encode(
                        Entity.ATTRIBUTE_TYPEHASH, Ident32.unwrap(attr.name), attr.valueType, _valueHash(attr.value)
                    )
                )
            )
        );
        assertEq(_hashOne(attr), expected);
    }

    function test_attributeHash_entityKey_matchesManualEIP712Encoding() public view {
        bytes32 ref = keccak256("some-entity");
        Entity.Attribute memory attr = Lib.entityKeyAttr("parent", ref);
        bytes32 expected = keccak256(
            abi.encodePacked(
                bytes32(0),
                keccak256(
                    abi.encode(
                        Entity.ATTRIBUTE_TYPEHASH, Ident32.unwrap(attr.name), attr.valueType, _valueHash(attr.value)
                    )
                )
            )
        );
        assertEq(_hashOne(attr), expected);
    }

    // ---- Rolling hash ----

    function test_attributesHash_empty_returnsZero() public view {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        assertEq(_hashMany(attrs), bytes32(0));
    }

    function test_attributesHash_two_matchesManualChain() public view {
        Entity.Attribute memory a = Lib.uintAttr("count", 42);
        Entity.Attribute memory b = Lib.stringAttr("label", "hello");

        bytes32 hashA =
            keccak256(abi.encode(Entity.ATTRIBUTE_TYPEHASH, Ident32.unwrap(a.name), a.valueType, _valueHash(a.value)));
        bytes32 hashB =
            keccak256(abi.encode(Entity.ATTRIBUTE_TYPEHASH, Ident32.unwrap(b.name), b.valueType, _valueHash(b.value)));
        bytes32 chain = keccak256(abi.encodePacked(bytes32(0), hashA));
        chain = keccak256(abi.encodePacked(chain, hashB));

        Entity.Attribute[] memory attrs = new Entity.Attribute[](2);
        attrs[0] = a;
        attrs[1] = b;
        assertEq(_hashMany(attrs), chain);
    }

    // ---- Sorting / uniqueness ----

    function test_attributeHash_revertsOnUnsortedNames() public {
        vm.expectRevert(Entity.AttributesNotSorted.selector);
        this.doAttributeHash(Lib.packName("label"), bytes32(0), Lib.uintAttr("count", 42));
    }

    function test_attributeHash_revertsOnDuplicateNames() public {
        vm.expectRevert(Entity.AttributesNotSorted.selector);
        this.doAttributeHash(Lib.packName("count"), bytes32(0), Lib.uintAttr("count", 2));
    }

    // ---- Value type validation ----

    function test_attributeHash_revertsOnUninitializedValueType() public {
        bytes32[4] memory v;
        v[0] = bytes32(uint256(1));
        Entity.Attribute memory attr =
            Entity.Attribute({name: Lib.packName("bad"), valueType: Entity.UNINITIALIZED, value: v});
        vm.expectRevert(abi.encodeWithSelector(Entity.InvalidValueType.selector, attr.name, Entity.UNINITIALIZED));
        _hashOne(attr);
    }

    function test_attributeHash_revertsOnValueTypeAboveRange() public {
        uint8 aboveRange = Entity.ATTR_ENTITY_KEY + 1;
        bytes32[4] memory v;
        Entity.Attribute memory attr = Entity.Attribute({name: Lib.packName("bad"), valueType: aboveRange, value: v});
        vm.expectRevert(abi.encodeWithSelector(Entity.InvalidValueType.selector, attr.name, aboveRange));
        _hashOne(attr);
    }

    // ---- Fuzz ----

    function _refHash(Entity.Attribute memory attr) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(Entity.ATTRIBUTE_TYPEHASH, Ident32.unwrap(attr.name), attr.valueType, _valueHash(attr.value))
        );
    }

    function _refChain(bytes32 prev, bytes32 h) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, h));
    }

    /// @dev Check that a bytes32 is a valid Ident32 (a-z leading, then a-z0-9._- , left-aligned).
    function _isValidIdent(bytes32 name) internal pure returns (bool) {
        uint8 b0 = uint8(name[0]);
        if ((IDENT_LEADING >> b0) & 1 == 0) return false;
        bool ended;
        for (uint256 i = 1; i < 32; i++) {
            uint8 b = uint8(name[i]);
            if (b == 0) {
                ended = true;
                continue;
            }
            if (ended) return false;
            if ((IDENT_CHARSET >> b) & 1 == 0) return false;
        }
        return true;
    }

    function test_attributeHash_fuzz_uint(bytes32 name, uint256 value) public {
        vm.assume(_isValidIdent(name));
        bytes32[4] memory v;
        v[0] = bytes32(value);
        Entity.Attribute memory attr =
            Entity.Attribute({name: Ident32.wrap(name), valueType: Entity.ATTR_UINT, value: v});
        (, bytes32 chain) = this.doAttributeHash(Ident32.wrap(bytes32(0)), bytes32(0), attr);
        assertEq(chain, _refChain(bytes32(0), _refHash(attr)));
    }

    function test_attributeHash_fuzz_entityKey(bytes32 name, bytes32 value) public {
        vm.assume(_isValidIdent(name));
        bytes32[4] memory v;
        v[0] = value;
        Entity.Attribute memory attr =
            Entity.Attribute({name: Ident32.wrap(name), valueType: Entity.ATTR_ENTITY_KEY, value: v});
        (, bytes32 chain) = this.doAttributeHash(Ident32.wrap(bytes32(0)), bytes32(0), attr);
        assertEq(chain, _refChain(bytes32(0), _refHash(attr)));
    }

    function test_attributeHash_fuzz_string(bytes32 name, bytes32[4] calldata value) public {
        vm.assume(_isValidIdent(name));
        Entity.Attribute memory attr =
            Entity.Attribute({name: Ident32.wrap(name), valueType: Entity.ATTR_STRING, value: value});
        (, bytes32 chain) = this.doAttributeHash(Ident32.wrap(bytes32(0)), bytes32(0), attr);
        assertEq(chain, _refChain(bytes32(0), _refHash(attr)));
    }
}
