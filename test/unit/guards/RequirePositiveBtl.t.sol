// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber32} from "../../../contracts/types/BlockNumber32.sol";
import {Test} from "forge-std/Test.sol";
import {Entity} from "../../../contracts/Entity.sol";
import {EntityRegistry} from "../../../contracts/EntityRegistry.sol";

contract RequirePositiveBtlTest is Test, EntityRegistry {
    function doRequirePositiveBtl(BlockNumber32 btl) external pure {
        Entity.requirePositiveBtl(btl);
    }

    function test_positiveBtl_succeeds() public view {
        this.doRequirePositiveBtl(BlockNumber32.wrap(1));
    }

    function test_largeBtl_succeeds() public view {
        this.doRequirePositiveBtl(BlockNumber32.wrap(999999));
    }

    function test_zeroBtl_reverts() public {
        vm.expectRevert(Entity.ZeroBtl.selector);
        this.doRequirePositiveBtl(BlockNumber32.wrap(0));
    }
}
