// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber, currentBlock} from "../../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../src/Entity.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {encodeMime128} from "../../../src/types/Mime128.sol";

contract RequireOwnerTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doRequireOwner(bytes32 key) external view {
        Entity.Commitment storage c = _commitments[key];
        Entity.requireOwner(key, c);
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(op);
    }

    function test_owner_succeeds() public {
        vm.prank(alice);
        this.doRequireOwner(testKey);
    }

    function test_notOwner_reverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Entity.NotOwner.selector, testKey, bob, alice));
        this.doRequireOwner(testKey);
    }

    function test_zeroAddress_reverts() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(Entity.NotOwner.selector, testKey, address(0), alice));
        this.doRequireOwner(testKey);
    }
}
