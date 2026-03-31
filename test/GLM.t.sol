// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GlmToken} from "../src/GLM.sol";

contract GLMTest is Test {
    GlmToken glm;
    address deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        glm = new GlmToken();
    }

    function test_nameAndSymbol() public view {
        // GIVEN a deployed GLM token
        // WHEN querying name and symbol
        // THEN they match the expected values
        assertEq(glm.name(), "Golem");
        assertEq(glm.symbol(), "GLM");
    }

    function test_decimals() public view {
        // GIVEN a deployed GLM token
        // WHEN querying decimals
        // THEN it returns the ERC20 default of 18
        assertEq(glm.decimals(), 18);
    }

    function test_initialSupply_isZero() public view {
        // GIVEN a deployed GLM token
        // WHEN querying total supply
        // THEN it is zero (no minting in constructor)
        assertEq(glm.totalSupply(), 0);
    }
}
