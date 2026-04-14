// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract RequireFutureExpiryTest is Test, EntityRegistry {
    BlockNumber constant CURRENT = BlockNumber.wrap(1000);

    function doRequireFutureExpiry(BlockNumber expiresAt, BlockNumber current) external pure {
        EntityHashing.requireFutureExpiry(expiresAt, current);
    }

    function test_futureExpiry_succeeds() public view {
        this.doRequireFutureExpiry(BlockNumber.wrap(1001), CURRENT);
    }

    function test_farFutureExpiry_succeeds() public view {
        this.doRequireFutureExpiry(BlockNumber.wrap(999999), CURRENT);
    }

    function test_equalToCurrentBlock_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.ExpiryInPast.selector, CURRENT, CURRENT));
        this.doRequireFutureExpiry(CURRENT, CURRENT);
    }

    function test_beforeCurrentBlock_reverts() public {
        BlockNumber past = BlockNumber.wrap(500);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.ExpiryInPast.selector, past, CURRENT));
        this.doRequireFutureExpiry(past, CURRENT);
    }
}
