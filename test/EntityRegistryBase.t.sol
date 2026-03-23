// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EntityRegistry} from "../src/EntityRegistry.sol";

contract EntityRegistryBase is Test {
    using ShortStrings for *;

    EntityRegistry registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual {
        registry = new EntityRegistry();
    }

    // -------------------------------------------------------------------------
    // Attribute builders
    // -------------------------------------------------------------------------

    function _uintAttr(string memory name, uint256 value) internal pure returns (EntityRegistry.Attribute memory) {
        return EntityRegistry.Attribute({
            name: name.toShortString(),
            valueType: EntityRegistry.AttributeType.UINT,
            fixedValue: bytes32(value),
            stringValue: ""
        });
    }

    function _stringAttr(string memory name, string memory value)
        internal
        view
        returns (EntityRegistry.Attribute memory)
    {
        return EntityRegistry.Attribute({
            name: name.toShortString(),
            valueType: EntityRegistry.AttributeType.STRING,
            fixedValue: bytes32(0),
            stringValue: value
        });
    }

    function _entityKeyAttr(string memory name, bytes32 value) internal pure returns (EntityRegistry.Attribute memory) {
        return EntityRegistry.Attribute({
            name: name.toShortString(),
            valueType: EntityRegistry.AttributeType.ENTITY_KEY,
            fixedValue: value,
            stringValue: ""
        });
    }

    // -------------------------------------------------------------------------
    // Payload builders
    // -------------------------------------------------------------------------

    function _payload(uint256 size) internal pure returns (bytes memory) {
        return new bytes(size);
    }
}
