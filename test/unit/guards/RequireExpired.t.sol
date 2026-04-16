// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber, currentBlock} from "../../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../src/Entity.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {encodeMime128} from "../../../src/types/Mime128.sol";

contract RequireExpiredTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doRequireExpired(bytes32 key, BlockNumber current) external view {
        Entity.Commitment storage c = _commitments[key];
        Entity.requireExpired(key, c, current);
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(op);
    }

    function test_atExactExpiryBlock_succeeds() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        this.doRequireExpired(testKey, currentBlock());
    }

    function test_afterExpiryBlock_succeeds() public {
        vm.roll(BlockNumber.unwrap(expiresAt) + 100);
        this.doRequireExpired(testKey, currentBlock());
    }

    function test_beforeExpiry_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotExpired.selector, testKey, expiresAt));
        this.doRequireExpired(testKey, currentBlock());
    }

    function test_oneBlockBeforeExpiry_reverts() public {
        vm.roll(BlockNumber.unwrap(expiresAt) - 1);

        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotExpired.selector, testKey, expiresAt));
        this.doRequireExpired(testKey, currentBlock());
    }

    function test_callableByNonOwner() public {
        vm.roll(BlockNumber.unwrap(expiresAt));

        vm.prank(bob);
        this.doRequireExpired(testKey, currentBlock());
    }
}
