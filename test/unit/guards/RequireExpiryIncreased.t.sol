// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract RequireExpiryIncreasedTest is Test, EntityRegistry {
    bytes32 constant KEY = keccak256("test-key");
    BlockNumber constant CURRENT = BlockNumber.wrap(1000);

    function doRequireExpiryIncreased(bytes32 key, BlockNumber newExpiresAt, BlockNumber currentExpiresAt)
        external
        pure
    {
        _requireExpiryIncreased(key, newExpiresAt, currentExpiresAt);
    }

    function test_increased_succeeds() public view {
        this.doRequireExpiryIncreased(KEY, BlockNumber.wrap(1500), CURRENT);
    }

    function test_increasedByOne_succeeds() public view {
        this.doRequireExpiryIncreased(KEY, BlockNumber.wrap(1001), CURRENT);
    }

    function test_sameExpiry_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.ExpiryNotExtended.selector, KEY, CURRENT, CURRENT));
        this.doRequireExpiryIncreased(KEY, CURRENT, CURRENT);
    }

    function test_decreased_reverts() public {
        BlockNumber lower = BlockNumber.wrap(500);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.ExpiryNotExtended.selector, KEY, lower, CURRENT));
        this.doRequireExpiryIncreased(KEY, lower, CURRENT);
    }
}
