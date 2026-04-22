// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber} from "../../../contracts/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {Entity} from "../../../contracts/Entity.sol";
import {EntityRegistry} from "../../../contracts/EntityRegistry.sol";
import {encodeMime128} from "../../../contracts/types/Mime128.sol";

contract RequireExistsTest is Test, EntityRegistry {
    address alice = makeAddr("alice");

    BlockNumber expiresAt;
    bytes32 testKey;

    function doCreate(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _create(op, BlockNumber.wrap(uint32(block.number)));
    }

    function doRequireExists(bytes32 key) external view {
        Entity.Commitment storage c = _commitments[key];
        Entity.requireExists(key, c);
    }

    function setUp() public {
        expiresAt = BlockNumber.wrap(uint32(block.number)) + BlockNumber.wrap(1000);

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation memory op = Lib.createOp("hello", encodeMime128("text/plain"), attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(op);
    }

    function test_existingEntity_succeeds() public view {
        this.doRequireExists(testKey);
    }

    function test_nonExistentEntity_reverts() public {
        bytes32 bogus = keccak256("bogus");
        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, bogus));
        this.doRequireExists(bogus);
    }

    function test_deletedEntity_reverts() public {
        this.doRequireExists(testKey); // exists before delete
        delete _commitments[testKey];

        vm.expectRevert(abi.encodeWithSelector(Entity.EntityNotFound.selector, testKey));
        this.doRequireExists(testKey);
    }
}
