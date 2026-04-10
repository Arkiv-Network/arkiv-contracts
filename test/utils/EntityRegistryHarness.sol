// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../src/BlockNumber.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";

contract EntityRegistryHarness is EntityRegistry {
    function exposed_attributeHash(bytes32 prevName, bytes32 chain, EntityHashing.Attribute calldata attr)
        external
        pure
        returns (bytes32, bytes32)
    {
        return EntityHashing.attributeHash(prevName, chain, attr);
    }

    function exposed_coreHash(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        string calldata contentType,
        bytes calldata payload,
        EntityHashing.Attribute[] calldata attributes
    ) external pure returns (bytes32) {
        return EntityHashing.coreHash(key, creator, createdAt, contentType, payload, attributes);
    }

    function exposed_entityHash(bytes32 coreHash_, address owner, BlockNumber updatedAt, BlockNumber expiresAt)
        external
        view
        returns (bytes32)
    {
        return _entityHash(coreHash_, owner, updatedAt, expiresAt);
    }
}
