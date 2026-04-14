// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract RequireNewOwnerTest is Test, EntityRegistry {
    bytes32 constant KEY = keccak256("test-key");

    function doRequireNewOwner(bytes32 key, address newOwner, address currentOwner) external pure {
        EntityHashing.requireNewOwner(key, newOwner, currentOwner);
    }

    function test_differentOwner_succeeds() public {
        this.doRequireNewOwner(KEY, makeAddr("bob"), makeAddr("alice"));
    }

    function test_sameOwner_reverts() public {
        address alice = makeAddr("alice");
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.TransferToSelf.selector, KEY));
        this.doRequireNewOwner(KEY, alice, alice);
    }
}
