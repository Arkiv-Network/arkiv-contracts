// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";

/// @dev Harness for testing individual op functions in isolation.
/// Overrides _validateAttributes to a no-op so op tests focus on
/// state logic, not attribute validation.
contract OpHarness is EntityRegistry {
    function _validateAttributes(EntityHashing.Attribute[] calldata) internal pure override {}

    function exposed_create(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function exposed_update(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _update(op, currentBlock());
    }

    function exposed_extend(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _extend(op, currentBlock());
    }

    function exposed_transfer(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _transfer(op, currentBlock());
    }

    function exposed_delete(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _delete(op, currentBlock());
    }

    function exposed_expire(bytes32 key) external returns (bytes32, bytes32) {
        return _expire(key, currentBlock());
    }

    // Hash helpers for manual verification in tests.
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
