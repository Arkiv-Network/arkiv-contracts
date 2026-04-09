// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";

/// @dev Exposes _validateAttributes for direct unit testing.
contract ValidateAttributesHarness is EntityRegistry {
    function exposed_validateAttributes(EntityHashing.Attribute[] calldata attributes) external pure {
        _validateAttributes(attributes);
    }
}
