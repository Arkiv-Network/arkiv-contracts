// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";

contract ValidateAttributesTest is Test, EntityRegistry {
    // Calldata wrapper — _validateAttributes takes calldata arrays.
    function validate(EntityHashing.Attribute[] calldata attributes) external pure {
        _validateAttributes(attributes);
    }

    // =========================================================================
    // Attribute count
    // =========================================================================

    function test_tooManyAttributes_reverts() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](33);
        for (uint256 i = 0; i < 33; i++) {
            bytes memory name = new bytes(1);
            name[0] = bytes1(uint8(0x41 + i));
            attrs[i] = Lib.uintAttr(string(name), i);
        }

        vm.expectRevert(abi.encodeWithSelector(EntityHashing.TooManyAttributes.selector, 33, 32));
        this.validate(attrs);
    }

    function test_maxAttributes_succeeds() public view {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](32);
        for (uint256 i = 0; i < 32; i++) {
            bytes memory name = new bytes(1);
            name[0] = bytes1(uint8(0x41 + i));
            attrs[i] = Lib.uintAttr(string(name), i);
        }

        this.validate(attrs);
    }

    function test_emptyAttributes_succeeds() public view {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        this.validate(attrs);
    }
}
