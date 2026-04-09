// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";
import {ValidateAttributesHarness} from "../utils/harness/ValidateAttributesHarness.sol";

contract ValidateAttributesTest is Test {
    ValidateAttributesHarness harness;

    function setUp() public {
        harness = new ValidateAttributesHarness();
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
        harness.exposed_validateAttributes(attrs);
    }

    function test_maxAttributes_succeeds() public view {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](32);
        for (uint256 i = 0; i < 32; i++) {
            bytes memory name = new bytes(1);
            name[0] = bytes1(uint8(0x41 + i));
            attrs[i] = Lib.uintAttr(string(name), i);
        }

        harness.exposed_validateAttributes(attrs);
    }

    function test_emptyAttributes_succeeds() public view {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        harness.exposed_validateAttributes(attrs);
    }
}
