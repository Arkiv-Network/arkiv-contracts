// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract RequireNonZeroAddressTest is Test, EntityRegistry {
    bytes32 constant KEY = keccak256("test-key");

    function doRequireNonZeroAddress(bytes32 key, address addr) external pure {
        _requireNonZeroAddress(key, addr);
    }

    function test_nonZeroAddress_succeeds() public view {
        this.doRequireNonZeroAddress(KEY, address(1));
    }

    function test_normalAddress_succeeds() public {
        this.doRequireNonZeroAddress(KEY, makeAddr("alice"));
    }

    function test_zeroAddress_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.TransferToZeroAddress.selector, KEY));
        this.doRequireNonZeroAddress(KEY, address(0));
    }
}
