// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract RequireActiveTest is Test, EntityRegistry {
    address alice = makeAddr("alice");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doRequireActive(bytes32 key, BlockNumber current) external view {
        EntityHashing.Commitment storage c = _commitments[key];
        EntityHashing.requireActive(key, c, current);
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(op);
    }

    function test_beforeExpiry_succeeds() public view {
        this.doRequireActive(testKey, currentBlock());
    }

    function test_atExpiryBlock_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doRequireActive(testKey, currentBlock());
    }

    function test_afterExpiry_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt) + 1);

        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityExpired.selector, testKey, expiresAt));
        this.doRequireActive(testKey, currentBlock());
    }
}
