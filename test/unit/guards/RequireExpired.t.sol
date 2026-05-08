// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber32} from "../../../contracts/types/BlockNumber32.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../contracts/Entity.sol";
import {EntityRegistry} from "../../../contracts/EntityRegistry.sol";
import {encodeMime128} from "../../../contracts/types/Mime128.sol";

contract RequireExpiredTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber32 btl;
    BlockNumber32 expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, BlockNumber32.wrap(uint32(block.number)));
    }

    function doRequireExpired(bytes32 key, BlockNumber32 current) external view {
        Entity.Commitment storage c = _commitments[key];
        Entity.requireExpired(key, c, current);
    }

    function setUp() public {
        btl = BlockNumber32.wrap(1000);
        expiresAt = BlockNumber32.wrap(uint32(block.number)) + btl;

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.createOp("hello", encodeMime128("text/plain"), attrs, btl);
        vm.prank(alice);
        (testKey,) = this.doCreate(op);
    }

    function test_atExactExpiryBlock_succeeds() public {
        vm.roll(BlockNumber32.unwrap(expiresAt));
        this.doRequireExpired(testKey, BlockNumber32.wrap(uint32(block.number)));
    }

    function test_afterExpiryBlock_succeeds() public {
        vm.roll(BlockNumber32.unwrap(expiresAt) + 100);
        this.doRequireExpired(testKey, BlockNumber32.wrap(uint32(block.number)));
    }

    function test_beforeExpiry_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotExpired.selector, testKey, expiresAt));
        this.doRequireExpired(testKey, BlockNumber32.wrap(uint32(block.number)));
    }

    function test_oneBlockBeforeExpiry_reverts() public {
        vm.roll(BlockNumber32.unwrap(expiresAt) - 1);

        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotExpired.selector, testKey, expiresAt));
        this.doRequireExpired(testKey, BlockNumber32.wrap(uint32(block.number)));
    }

    function test_callableByNonOwner() public {
        vm.roll(BlockNumber32.unwrap(expiresAt));

        vm.prank(bob);
        this.doRequireExpired(testKey, BlockNumber32.wrap(uint32(block.number)));
    }
}
