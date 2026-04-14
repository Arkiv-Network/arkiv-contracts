// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract RequireOwnerTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doRequireOwner(bytes32 key) external view {
        EntityHashing.Commitment storage c = _commitments[key];
        _requireOwner(key, c);
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(op);
    }

    function test_owner_succeeds() public {
        vm.prank(alice);
        this.doRequireOwner(testKey);
    }

    function test_notOwner_reverts() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.NotOwner.selector, testKey, bob, alice));
        this.doRequireOwner(testKey);
    }

    function test_zeroAddress_reverts() public {
        vm.prank(address(0));
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.NotOwner.selector, testKey, address(0), alice));
        this.doRequireOwner(testKey);
    }
}
