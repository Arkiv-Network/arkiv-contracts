// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EntityRegistry} from "../../src/EntityRegistry.sol";

contract EntityRegistryHarness is EntityRegistry {
    function exposed_entityHash(bytes32 coreHash_, address owner, uint32 updatedAt, uint32 expiresAt)
        external
        view
        returns (bytes32)
    {
        return _entityHash(coreHash_, owner, updatedAt, expiresAt);
    }
}
