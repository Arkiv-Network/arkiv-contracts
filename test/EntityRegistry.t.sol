// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EntityRegistryBase} from "./EntityRegistryBase.t.sol";
import {EntityRegistry} from "../src/EntityRegistry.sol";

contract EntityRegistryValidateEntityTest is EntityRegistryBase {
    using ShortStrings for *;

    // -------------------------------------------------------------------------
    // validateEntity — payload size
    // -------------------------------------------------------------------------

    function test_validateEntity_payloadAtLimit_succeeds() public view {
        // GIVEN a payload exactly at the size limit
        bytes memory payload = _payload(registry.MAX_PAYLOAD_SIZE());
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](0);

        // WHEN / THEN no revert
        registry.validateEntity(payload, attributes);
    }

    function test_validateEntity_payloadOverLimit_reverts() public {
        // GIVEN a payload one byte over the size limit
        bytes memory payload = _payload(registry.MAX_PAYLOAD_SIZE() + 1);
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](0);

        // WHEN / THEN
        vm.expectRevert(
            abi.encodeWithSelector(
                EntityRegistry.PayloadTooLarge.selector, registry.MAX_PAYLOAD_SIZE() + 1, registry.MAX_PAYLOAD_SIZE()
            )
        );
        registry.validateEntity(payload, attributes);
    }

    // -------------------------------------------------------------------------
    // validateEntity — attribute count
    // -------------------------------------------------------------------------

    function test_validateEntity_attributesAtLimit_succeeds() public view {
        // GIVEN attributes exactly at the count limit, sorted by name
        uint256 max = registry.MAX_ATTRIBUTES();
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](max);
        for (uint256 i = 0; i < max; i++) {
            // zero-pad index to 3 chars so lexicographic order matches numeric order
            attributes[i] = _uintAttr(string(abi.encodePacked("attr", _pad3(i))), i);
        }

        // WHEN / THEN no revert
        registry.validateEntity(_payload(0), attributes);
    }

    function test_validateEntity_tooManyAttributes_reverts() public {
        // GIVEN one more attribute than the limit
        uint256 max = registry.MAX_ATTRIBUTES();
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](max + 1);
        for (uint256 i = 0; i <= max; i++) {
            attributes[i] = _uintAttr(string(abi.encodePacked("attr", _pad3(i))), i);
        }

        // WHEN / THEN
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.TooManyAttributes.selector, max + 1, max));
        registry.validateEntity(_payload(0), attributes);
    }

    // -------------------------------------------------------------------------
    // validateEntity — string attribute size
    // -------------------------------------------------------------------------

    function test_validateEntity_stringAttrAtLimit_succeeds() public view {
        // GIVEN a string attribute exactly at the size limit
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](1);
        attributes[0] = _stringAttr("name", _repeatChar("x", registry.MAX_STRING_ATTR_SIZE()));

        // WHEN / THEN no revert
        registry.validateEntity(_payload(0), attributes);
    }

    function test_validateEntity_stringAttrOverLimit_reverts() public {
        // GIVEN a string attribute one byte over the size limit
        uint256 max = registry.MAX_STRING_ATTR_SIZE();
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](1);
        attributes[0] = _stringAttr("name", _repeatChar("x", max + 1));

        // WHEN / THEN
        vm.expectRevert(
            abi.encodeWithSelector(EntityRegistry.StringAttributeTooLarge.selector, attributes[0].name, max + 1, max)
        );
        registry.validateEntity(_payload(0), attributes);
    }

    // -------------------------------------------------------------------------
    // validateEntity — attribute ordering
    // -------------------------------------------------------------------------

    function test_validateEntity_sortedAttributes_succeeds() public view {
        // GIVEN attributes in ascending name order
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](3);
        attributes[0] = _uintAttr("aaa", 1);
        attributes[1] = _uintAttr("bbb", 2);
        attributes[2] = _uintAttr("ccc", 3);

        // WHEN / THEN no revert
        registry.validateEntity(_payload(0), attributes);
    }

    function test_validateEntity_unsortedAttributes_reverts() public {
        // GIVEN attributes out of order
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](2);
        attributes[0] = _uintAttr("bbb", 1);
        attributes[1] = _uintAttr("aaa", 2);

        // WHEN / THEN
        vm.expectRevert(
            abi.encodeWithSelector(EntityRegistry.AttributesNotSorted.selector, attributes[1].name, attributes[0].name)
        );
        registry.validateEntity(_payload(0), attributes);
    }

    function test_validateEntity_duplicateAttributeNames_reverts() public {
        // GIVEN two attributes with the same name (equal names fail the strict > check)
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](2);
        attributes[0] = _uintAttr("name", 1);
        attributes[1] = _uintAttr("name", 2);

        // WHEN / THEN
        vm.expectRevert(
            abi.encodeWithSelector(EntityRegistry.AttributesNotSorted.selector, attributes[1].name, attributes[0].name)
        );
        registry.validateEntity(_payload(0), attributes);
    }

    function test_validateEntity_emptyAttributeName_reverts() public {
        // GIVEN an attribute with an empty name
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](1);
        attributes[0] = EntityRegistry.Attribute({
            name: ShortStrings.toShortString(""),
            valueType: EntityRegistry.AttributeType.UINT,
            fixedValue: bytes32(uint256(1)),
            stringValue: ""
        });

        // WHEN / THEN
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.EmptyAttributeName.selector, 0));
        registry.validateEntity(_payload(0), attributes);
    }

    function test_validateEntity_emptyAttributes_succeeds() public view {
        // GIVEN no attributes
        EntityRegistry.Attribute[] memory attributes = new EntityRegistry.Attribute[](0);

        // WHEN / THEN no revert
        registry.validateEntity(_payload(0), attributes);
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _pad3(uint256 n) internal pure returns (bytes memory) {
        bytes memory result = new bytes(3);
        result[2] = bytes1(uint8(48 + (n % 10)));
        result[1] = bytes1(uint8(48 + ((n / 10) % 10)));
        result[0] = bytes1(uint8(48 + ((n / 100) % 10)));
        return result;
    }

    function _repeatChar(string memory char, uint256 count) internal pure returns (string memory) {
        bytes memory result = new bytes(count);
        bytes memory charBytes = bytes(char);
        for (uint256 i = 0; i < count; i++) {
            result[i] = charBytes[0];
        }
        return string(result);
    }
}
