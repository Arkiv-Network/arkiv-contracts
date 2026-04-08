// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";

library Lib {
    using ShortStrings for *;

    function uintAttr(string memory name, uint256 value) internal pure returns (EntityRegistry.Attribute memory) {
        return EntityRegistry.Attribute({
            name: name.toShortString(),
            valueType: EntityRegistry.AttributeType.UINT,
            fixedValue: bytes32(value),
            stringValue: ""
        });
    }

    function stringAttr(string memory name, string memory value)
        internal
        pure
        returns (EntityRegistry.Attribute memory)
    {
        return EntityRegistry.Attribute({
            name: name.toShortString(),
            valueType: EntityRegistry.AttributeType.STRING,
            fixedValue: bytes32(0),
            stringValue: value
        });
    }

    function entityKeyAttr(string memory name, bytes32 value) internal pure returns (EntityRegistry.Attribute memory) {
        return EntityRegistry.Attribute({
            name: name.toShortString(),
            valueType: EntityRegistry.AttributeType.ENTITY_KEY,
            fixedValue: value,
            stringValue: ""
        });
    }

    function payload(uint256 size) internal pure returns (bytes memory) {
        return new bytes(size);
    }
}
