// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../src/BlockNumber.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";
import {Ident32, encodeIdent32} from "../../src/Ident32.sol";
import {Mime128} from "../../src/types/Mime128.sol";

library Lib {
    /// @dev Pack a string into a validated, left-aligned, zero-padded Ident32.
    function packName(string memory name) internal pure returns (Ident32) {
        return encodeIdent32(name);
    }

    function createOp(
        bytes memory payload_,
        Mime128 memory contentType_,
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

    function updateOp(
        bytes32 entityKey_,
        bytes memory payload_,
        Mime128 memory contentType_,
        EntityHashing.Attribute[] memory attributes_
    ) internal pure returns (EntityHashing.Op memory) {
        return EntityHashing.Op({
            opType: EntityHashing.UPDATE,
            entityKey: entityKey_,
            payload: payload_,
            contentType: contentType_,
            attributes: attributes_,
            expiresAt: BlockNumber.wrap(0),
            newOwner: address(0)
        });
    }

    function deleteOp(bytes32 entityKey_) internal pure returns (EntityHashing.Op memory) {
        EntityHashing.Attribute[] memory empty = new EntityHashing.Attribute[](0);
        Mime128 memory emptyCt;
        return EntityHashing.Op({
            opType: EntityHashing.DELETE,
            entityKey: entityKey_,
            payload: "",
            contentType: emptyCt,
            attributes: empty,
            expiresAt: BlockNumber.wrap(0),
            newOwner: address(0)
        });
    }

    function transferOp(bytes32 entityKey_, address newOwner_) internal pure returns (EntityHashing.Op memory) {
        EntityHashing.Attribute[] memory empty = new EntityHashing.Attribute[](0);
        Mime128 memory emptyCt;
        return EntityHashing.Op({
            opType: EntityHashing.TRANSFER,
            entityKey: entityKey_,
            payload: "",
            contentType: emptyCt,
            attributes: empty,
            expiresAt: BlockNumber.wrap(0),
            newOwner: newOwner_
        });
    }

    function expireOp(bytes32 entityKey_) internal pure returns (EntityHashing.Op memory) {
        EntityHashing.Attribute[] memory empty = new EntityHashing.Attribute[](0);
        Mime128 memory emptyCt;
        return EntityHashing.Op({
            opType: EntityHashing.EXPIRE,
            entityKey: entityKey_,
            payload: "",
            contentType: emptyCt,
            attributes: empty,
            expiresAt: BlockNumber.wrap(0),
            newOwner: address(0)
        });
    }

    function extendOp(bytes32 entityKey_, BlockNumber expiresAt_) internal pure returns (EntityHashing.Op memory) {
        EntityHashing.Attribute[] memory empty = new EntityHashing.Attribute[](0);
        Mime128 memory emptyCt;
        return EntityHashing.Op({
            opType: EntityHashing.EXTEND,
            entityKey: entityKey_,
            payload: "",
            contentType: emptyCt,
            attributes: empty,
            expiresAt: expiresAt_,
            newOwner: address(0)
        });
    }

    function uintAttr(string memory name, uint256 value) internal pure returns (EntityHashing.Attribute memory) {
        bytes32[4] memory v;
        v[0] = bytes32(value);
        return EntityHashing.Attribute({name: packName(name), valueType: EntityHashing.ATTR_UINT, value: v});
    }

    function stringAttr(string memory name, string memory value)
        internal
        pure
        returns (EntityHashing.Attribute memory)
    {
        bytes memory b = bytes(value);
        bytes32[4] memory v;
        for (uint256 i = 0; i < b.length; i++) {
            uint256 slot = i / 32;
            uint256 offset = i % 32;
            v[slot] |= bytes32(bytes1(b[i])) >> (offset * 8);
        }
        return EntityHashing.Attribute({name: packName(name), valueType: EntityHashing.ATTR_STRING, value: v});
    }

    function entityKeyAttr(string memory name, bytes32 value) internal pure returns (EntityHashing.Attribute memory) {
        bytes32[4] memory v;
        v[0] = value;
        return EntityHashing.Attribute({name: packName(name), valueType: EntityHashing.ATTR_ENTITY_KEY, value: v});
    }

    function payload(uint256 size) internal pure returns (bytes memory) {
        return new bytes(size);
    }
}
