// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract AttributeHashTest is Test, EntityRegistry {
    function doAttributeHash(bytes32 prevName, bytes32 chain, EntityHashing.Attribute calldata attr)
        external
        pure
        returns (bytes32, bytes32)
    {
        return EntityHashing.attributeHash(prevName, chain, attr);
    }

    function _hashOne(EntityHashing.Attribute memory attr) internal view returns (bytes32) {
        (, bytes32 chain) = this.doAttributeHash(bytes32(0), bytes32(0), attr);
        return chain;
    }

    function _hashMany(EntityHashing.Attribute[] memory attrs) internal view returns (bytes32) {
        bytes32 chain;
        bytes32 prevName;
        for (uint256 i = 0; i < attrs.length; i++) {
            (prevName, chain) = this.doAttributeHash(prevName, chain, attrs[i]);
        }
        return chain;
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

    // ---- Rolling hash ----

    function test_attributesHash_empty_returnsZero() public view {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        assertEq(_hashMany(attrs), bytes32(0));
    }

    function test_attributesHash_two_matchesManualChain() public view {
        EntityHashing.Attribute memory a = Lib.uintAttr("count", 42);
        EntityHashing.Attribute memory b = Lib.stringAttr("label", "hello");

        bytes32 hashA = keccak256(abi.encode(EntityHashing.ATTRIBUTE_TYPEHASH, a.name, a.valueType, keccak256(a.value)));
        bytes32 hashB = keccak256(abi.encode(EntityHashing.ATTRIBUTE_TYPEHASH, b.name, b.valueType, keccak256(b.value)));
        bytes32 chain = keccak256(abi.encodePacked(bytes32(0), hashA));
        chain = keccak256(abi.encodePacked(chain, hashB));

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = a;
        attrs[1] = b;
        assertEq(_hashMany(attrs), chain);
    }

    // ---- Sorting / uniqueness ----

    function test_attributeHash_revertsOnUnsortedNames() public {
        vm.expectRevert(EntityHashing.AttributesNotSorted.selector);
        this.doAttributeHash(Lib.packName("label"), bytes32(0), Lib.uintAttr("count", 42));
    }

    function test_attributeHash_revertsOnDuplicateNames() public {
        vm.expectRevert(EntityHashing.AttributesNotSorted.selector);
        this.doAttributeHash(Lib.packName("count"), bytes32(0), Lib.uintAttr("count", 2));
    }

    // ---- Value type validation ----

    function test_attributeHash_revertsOnUintWrongLength() public {
        EntityHashing.Attribute memory attr =
            EntityHashing.Attribute({name: Lib.packName("count"), valueType: EntityHashing.ATTR_UINT, value: hex"01"});
        vm.expectRevert(
            abi.encodeWithSelector(EntityHashing.InvalidValueLength.selector, attr.name, EntityHashing.ATTR_UINT, 1)
        );
        _hashOne(attr);
    }

    function test_attributeHash_revertsOnEntityKeyWrongLength() public {
        EntityHashing.Attribute memory attr = EntityHashing.Attribute({
            name: Lib.packName("ref"), valueType: EntityHashing.ATTR_ENTITY_KEY, value: hex"abcd"
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                EntityHashing.InvalidValueLength.selector, attr.name, EntityHashing.ATTR_ENTITY_KEY, 2
            )
        );
        _hashOne(attr);
    }

    function test_attributeHash_revertsOnStringTooLarge() public {
        EntityHashing.Attribute memory attr = EntityHashing.Attribute({
            name: Lib.packName("bio"), valueType: EntityHashing.ATTR_STRING, value: new bytes(1025)
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                EntityHashing.InvalidValueLength.selector, attr.name, EntityHashing.ATTR_STRING, 1025
            )
        );
        _hashOne(attr);
    }

    function test_attributeHash_acceptsStringAtMaxSize() public view {
        _hashOne(
            EntityHashing.Attribute({
                name: Lib.packName("bio"), valueType: EntityHashing.ATTR_STRING, value: new bytes(1024)
            })
        );
    }

    function test_attributeHash_revertsOnInvalidValueType() public {
        EntityHashing.Attribute memory attr =
            EntityHashing.Attribute({name: Lib.packName("bad"), valueType: 99, value: hex"00"});
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.InvalidValueType.selector, attr.name, 99));
        _hashOne(attr);
    }

    // ---- Fuzz ----

    function _refHash(EntityHashing.Attribute memory attr) internal pure returns (bytes32) {
        return keccak256(abi.encode(EntityHashing.ATTRIBUTE_TYPEHASH, attr.name, attr.valueType, keccak256(attr.value)));
    }

    function _refChain(bytes32 prev, bytes32 h) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(prev, h));
    }

    function test_attributeHash_fuzz_uint(bytes32 name, uint256 value) public {
        vm.assume(name != bytes32(0));
        EntityHashing.Attribute memory attr =
            EntityHashing.Attribute({name: name, valueType: EntityHashing.ATTR_UINT, value: abi.encode(value)});
        (, bytes32 chain) = this.doAttributeHash(bytes32(0), bytes32(0), attr);
        assertEq(chain, _refChain(bytes32(0), _refHash(attr)));
    }

    function test_attributeHash_fuzz_entityKey(bytes32 name, bytes32 value) public {
        vm.assume(name != bytes32(0));
        EntityHashing.Attribute memory attr =
            EntityHashing.Attribute({name: name, valueType: EntityHashing.ATTR_ENTITY_KEY, value: abi.encode(value)});
        (, bytes32 chain) = this.doAttributeHash(bytes32(0), bytes32(0), attr);
        assertEq(chain, _refChain(bytes32(0), _refHash(attr)));
    }

    function test_attributeHash_fuzz_string(bytes32 name, bytes calldata value) public {
        vm.assume(name != bytes32(0));
        vm.assume(value.length <= 1024);
        EntityHashing.Attribute memory attr =
            EntityHashing.Attribute({name: name, valueType: EntityHashing.ATTR_STRING, value: value});
        (, bytes32 chain) = this.doAttributeHash(bytes32(0), bytes32(0), attr);
        assertEq(chain, _refChain(bytes32(0), _refHash(attr)));
    }
}
