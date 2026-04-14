// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract ExpireTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    BlockNumber expiresAt;
    bytes32 testKey;

    // Stub guard — tested separately in GuardEntityExpiry.t.sol.
    function _guardEntityExpiry(bytes32, EntityHashing.Commitment storage, BlockNumber) internal view override {}

    function doCreate(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _create(op, currentBlock());
    }

    function doExpire(bytes32 key) external returns (bytes32, bytes32) {
        return _expire(key, currentBlock());
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

    function test_expire_removesCommitment() public {
        this.doExpire(testKey);

        EntityHashing.Commitment memory c = getCommitment(testKey);
        assertEq(c.creator, address(0));
        assertEq(c.owner, address(0));
        assertEq(c.coreHash, bytes32(0));
        assertEq(BlockNumber.unwrap(c.createdAt), 0);
        assertEq(BlockNumber.unwrap(c.updatedAt), 0);
        assertEq(BlockNumber.unwrap(c.expiresAt), 0);
    }

    // =========================================================================
    // Return values
    // =========================================================================

    function test_expire_returnsEntityKey() public {
        (bytes32 returnedKey,) = this.doExpire(testKey);
        assertEq(returnedKey, testKey);
    }

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_expire_returnsSnapshotHash() public {
        EntityHashing.Commitment memory c = getCommitment(testKey);
        bytes32 expected = _wrapEntityHash(c.coreHash, c.owner, c.updatedAt, c.expiresAt);

        (, bytes32 entityHash_) = this.doExpire(testKey);
        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_expire_emitsEntityOp() public {
        vm.roll(BlockNumber.unwrap(expiresAt));
        vm.recordLogs();
        (, bytes32 entityHash_) = this.doExpire(testKey);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], EntityOp.selector);
        assertEq(logs[0].topics[1], testKey);
        assertEq(logs[0].topics[2], bytes32(uint256(EntityHashing.EXPIRE)));
        assertEq(logs[0].topics[3], bytes32(uint256(uint160(alice))));
        (BlockNumber emittedExpiry, bytes32 emittedHash) = abi.decode(logs[0].data, (BlockNumber, bytes32));
        assertEq(BlockNumber.unwrap(emittedExpiry), BlockNumber.unwrap(expiresAt));
        assertEq(emittedHash, entityHash_);
    }
}
