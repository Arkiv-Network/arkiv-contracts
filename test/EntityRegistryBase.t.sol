// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EntityRegistry} from "../src/EntityRegistry.sol";

/// @dev Test harness that exposes internal hash functions for verification.
contract EntityRegistryTestable is EntityRegistry {
    function attributeHash(Attribute calldata attr) external pure returns (bytes32) {
        return _attributeHash(attr);
    }

    function coreHash(
        bytes32 key,
        address creator,
        uint32 createdAt,
        string calldata contentType,
        bytes calldata payload,
        Attribute[] calldata attributes
    ) external pure returns (bytes32) {
        bytes32[] memory attrHashes = new bytes32[](attributes.length);
        for (uint256 i = 0; i < attributes.length; i++) {
            attrHashes[i] = _attributeHash(attributes[i]);
        }
        return _coreHash(key, creator, createdAt, contentType, payload, attrHashes);
    }
}

contract EntityRegistryBase is Test {
    using ShortStrings for *;

    EntityRegistryTestable registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual {
        registry = new EntityRegistryTestable();
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
