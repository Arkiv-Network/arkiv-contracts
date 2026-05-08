// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber32} from "../../../contracts/types/BlockNumber32.sol";
import {Test} from "forge-std/Test.sol";
import {Entity} from "../../../contracts/Entity.sol";
import {EntityRegistry} from "../../../contracts/EntityRegistry.sol";

contract RequireExpiryIncreasedTest is Test, EntityRegistry {
    bytes32 constant KEY = keccak256("test-key");
    BlockNumber32 constant CURRENT = BlockNumber32.wrap(1000);

    function doRequireExpiryIncreased(bytes32 key, BlockNumber32 newExpiresAt, BlockNumber32 currentExpiresAt)
        external
        pure
    {
        Entity.requireExpiryIncreased(key, newExpiresAt, currentExpiresAt);
    }

    function test_increased_succeeds() public view {
        this.doRequireExpiryIncreased(KEY, BlockNumber32.wrap(1500), CURRENT);
    }

    function test_increasedByOne_succeeds() public view {
        this.doRequireExpiryIncreased(KEY, BlockNumber32.wrap(1001), CURRENT);
    }

    function test_sameExpiry_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Entity.ExpiryNotExtended.selector, KEY, CURRENT, CURRENT));
        this.doRequireExpiryIncreased(KEY, CURRENT, CURRENT);
    }

    function test_decreased_reverts() public {
        BlockNumber32 lower = BlockNumber32.wrap(500);
        vm.expectRevert(abi.encodeWithSelector(Entity.ExpiryNotExtended.selector, KEY, lower, CURRENT));
        this.doRequireExpiryIncreased(KEY, lower, CURRENT);
    }
}
