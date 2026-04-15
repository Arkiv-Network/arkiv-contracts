// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Entity} from "../../src/Entity.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";

contract CreateEntityKeyTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function doCreateEntityKey(address owner) external returns (bytes32) {
        return _createEntityKey(owner);
    }

    // =========================================================================
    // Nonce
    // =========================================================================

    function test_incrementsNonce() public {
        assertEq(_nonces[alice], 0);

        vm.prank(alice);
        this.doCreateEntityKey(alice);
        assertEq(_nonces[alice], 1);

        vm.prank(alice);
        this.doCreateEntityKey(alice);
        assertEq(_nonces[alice], 2);
    }

    function test_independentNoncesPerOwner() public {
        vm.prank(alice);
        this.doCreateEntityKey(alice);

        vm.prank(bob);
        this.doCreateEntityKey(bob);

        assertEq(_nonces[alice], 1);
        assertEq(_nonces[bob], 1);
    }

    // =========================================================================
    // Key determinism
    // =========================================================================

    function test_keyMatchesEntityKeyFunction() public {
        bytes32 expectedKey = entityKey(alice, 0);

        vm.prank(alice);
        bytes32 key = this.doCreateEntityKey(alice);

        assertEq(key, expectedKey);
    }

    function test_secondKeyMatchesNonce1() public {
        vm.prank(alice);
        this.doCreateEntityKey(alice);

        bytes32 expectedKey = entityKey(alice, 1);

        vm.prank(alice);
        bytes32 key = this.doCreateEntityKey(alice);

        assertEq(key, expectedKey);
    }

    function test_differentOwners_differentKeys() public {
        vm.prank(alice);
        bytes32 keyAlice = this.doCreateEntityKey(alice);

        vm.prank(bob);
        bytes32 keyBob = this.doCreateEntityKey(bob);

        assertNotEq(keyAlice, keyBob);
    }
}
