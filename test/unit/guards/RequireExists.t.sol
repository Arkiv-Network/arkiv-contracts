// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";
import {encodeMime128} from "../../../src/types/Mime128.sol";

contract RequireExistsTest is Test, EntityRegistry {
    address alice = makeAddr("alice");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doRequireExists(bytes32 key) external view {
        EntityHashing.Commitment storage c = _commitments[key];
        EntityHashing.requireExists(key, c);
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(op);
    }

    function test_existingEntity_succeeds() public view {
        this.doRequireExists(testKey);
    }

    function test_nonExistentEntity_reverts() public {
        bytes32 bogus = keccak256("bogus");
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, bogus));
        this.doRequireExists(bogus);
    }

    function test_deletedEntity_reverts() public {
        this.doRequireExists(testKey); // exists before delete
        delete _commitments[testKey];

        vm.expectRevert(abi.encodeWithSelector(EntityHashing.EntityNotFound.selector, testKey));
        this.doRequireExists(testKey);
    }
}
