// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../src/BlockNumber.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";
import {Ident32} from "../../src/Ident32.sol";
import {Mime128} from "../../src/types/Mime128.sol";

/// @dev Harness for pure hash function tests (attributeHash, coreHash, entityStructHash).
/// No overrides — this is the real contract with exposed internals.
contract EntityRegistryHarness is EntityRegistry {
    function exposed_attributeHash(Ident32 prevName, bytes32 chain, EntityHashing.Attribute calldata attr)
        external
        pure
        returns (Ident32, bytes32)
    {
        return EntityHashing.attributeHash(prevName, chain, attr);
    }

    function exposed_coreHash(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        Mime128 calldata contentType,
        bytes calldata payload,
        EntityHashing.Attribute[] calldata attributes
    ) external pure returns (bytes32) {
        return EntityHashing.coreHash(key, creator, createdAt, contentType, payload, attributes);
    }
}
