// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Entity} from "../../../src/Entity.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract RequireFutureExpiryTest is Test, EntityRegistry {
    BlockNumber constant CURRENT = BlockNumber.wrap(1000);

    function doRequireFutureExpiry(BlockNumber expiresAt, BlockNumber current) external pure {
        Entity.requireFutureExpiry(expiresAt, current);
    }

    function test_futureExpiry_succeeds() public view {
        this.doRequireFutureExpiry(BlockNumber.wrap(1001), CURRENT);
    }

    function test_farFutureExpiry_succeeds() public view {
        this.doRequireFutureExpiry(BlockNumber.wrap(999999), CURRENT);
    }

    function test_equalToCurrentBlock_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Entity.ExpiryInPast.selector, CURRENT, CURRENT));
        this.doRequireFutureExpiry(CURRENT, CURRENT);
    }

    function test_beforeCurrentBlock_reverts() public {
        BlockNumber past = BlockNumber.wrap(500);
        vm.expectRevert(abi.encodeWithSelector(Entity.ExpiryInPast.selector, past, CURRENT));
        this.doRequireFutureExpiry(past, CURRENT);
    }
}
