// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract DeleteTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    // Stub guard — tested separately in GuardEntityMutation.t.sol.
    function _guardEntityMutation(bytes32, EntityHashing.Commitment storage, BlockNumber) internal view override {}

    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doDelete(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _delete(op, currentBlock());
    }

    function setUp() public {
        expiresAt = currentBlock() + BlockNumber.wrap(1000);

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory createOp = Lib.createOp("hello", "text/plain", attrs, expiresAt);
        vm.prank(alice);
        (testKey,) = this.doCreate(createOp);
    }

    // =========================================================================
    // State — commitment removed
    // =========================================================================

    function test_delete_removesCommitment() public {
        EntityHashing.Op memory op = Lib.deleteOp(testKey);

        vm.prank(alice);
        this.doDelete(op);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        assertEq(c.creator, address(0));
        assertEq(c.owner, address(0));
        assertEq(c.coreHash, bytes32(0));
        assertEq(BlockNumber.unwrap(c.createdAt), 0);
        assertEq(BlockNumber.unwrap(c.updatedAt), 0);
        assertEq(BlockNumber.unwrap(c.expiresAt), 0);
    }

    // =========================================================================
    // State — returns correct key
    // =========================================================================

    function test_delete_returnsEntityKey() public {
        EntityHashing.Op memory op = Lib.deleteOp(testKey);

        vm.prank(alice);
        (bytes32 returnedKey,) = this.doDelete(op);

        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_delete_returnsSnapshotHash() public {
        EntityHashing.Commitment memory c = getCommitment(testKey);
        bytes32 expected = _wrapEntityHash(c.coreHash, c.owner, c.updatedAt, c.expiresAt);

        EntityHashing.Op memory op = Lib.deleteOp(testKey);
        vm.prank(alice);
        (, bytes32 entityHash_) = this.doDelete(op);

        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_delete_emitsEntityOp() public {
        EntityHashing.Op memory op = Lib.deleteOp(testKey);

        vm.prank(alice);
        vm.recordLogs();
        (, bytes32 entityHash_) = this.doDelete(op);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EntityOp.selector);
        assertEq(logs[0].topics[1], testKey);
        assertEq(logs[0].topics[2], bytes32(uint256(EntityHashing.DELETE)));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(alice))));
        (BlockNumber emittedExpiry, bytes32 emittedHash) = abi.decode(logs[0].data, (BlockNumber, bytes32));
        assertEq(BlockNumber.unwrap(emittedExpiry), BlockNumber.unwrap(expiresAt));
        assertEq(emittedHash, entityHash_);
    }
}
