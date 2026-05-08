// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber} from "../../../contracts/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Entity} from "../../../contracts/Entity.sol";
import {EntityRegistry} from "../../../contracts/EntityRegistry.sol";

contract RequirePositiveBtlTest is Test, EntityRegistry {
    function doRequirePositiveBtl(BlockNumber btl) external pure {
        Entity.requirePositiveBtl(btl);
    }

    function test_positiveBtl_succeeds() public view {
        this.doRequirePositiveBtl(BlockNumber.wrap(1));
    }

    function test_largeBtl_succeeds() public view {
        this.doRequirePositiveBtl(BlockNumber.wrap(999999));
    }

    function test_zeroBtl_reverts() public {
        vm.expectRevert(Entity.ZeroBtl.selector);
        this.doRequirePositiveBtl(BlockNumber.wrap(0));
    }
}
