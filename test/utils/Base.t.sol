// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EntityRegistryHarness} from "./EntityRegistryHarness.sol";

contract Base is Test {
    EntityRegistryHarness registry;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public virtual {
        registry = new EntityRegistryHarness();
    }
}
