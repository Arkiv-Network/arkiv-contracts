// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../src/BlockNumber.sol";
import {ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";

library Lib {
    using ShortStrings for *;

    function createOp(
        bytes memory payload_,
        string memory contentType_,
        EntityHashing.Attribute[] memory attributes_,
        BlockNumber expiresAt_
    ) internal pure returns (EntityHashing.Op memory) {
        return EntityHashing.Op({
            opType: EntityHashing.CREATE,
            entityKey: bytes32(0),
            payload: payload_,
            contentType: contentType_,
            attributes: attributes_,
            expiresAt: expiresAt_,
            newOwner: address(0)
        });
    }

    function uintAttr(string memory name, uint256 value) internal pure returns (EntityHashing.Attribute memory) {
        return EntityHashing.Attribute({
            name: name.toShortString(),
            valueType: EntityHashing.AttributeType.UINT,
            fixedValue: bytes32(value),
            stringValue: ""
        });
    }

    function stringAttr(string memory name, string memory value)
        internal
        pure
        returns (EntityHashing.Attribute memory)
    {
        return EntityHashing.Attribute({
            name: name.toShortString(),
            valueType: EntityHashing.AttributeType.STRING,
            fixedValue: bytes32(0),
            stringValue: value
        });
    }

    function entityKeyAttr(string memory name, bytes32 value) internal pure returns (EntityHashing.Attribute memory) {
        return EntityHashing.Attribute({
            name: name.toShortString(),
            valueType: EntityHashing.AttributeType.ENTITY_KEY,
            fixedValue: value,
            stringValue: ""
        });
    }

    function payload(uint256 size) internal pure returns (bytes memory) {
        return new bytes(size);
    }
}
