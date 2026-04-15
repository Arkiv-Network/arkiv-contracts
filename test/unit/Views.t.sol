// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../utils/Lib.sol";
import {Entity} from "../../src/Entity.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {encodeMime128} from "../../src/types/Mime128.sol";

/// @dev Exercises every public view function via external calls so that
/// forge coverage counts them. Correctness of the underlying logic is
/// tested in Execute.t.sol and the ops/ tests.
contract ViewsTest is Test {
    EntityRegistry registry;

    address alice = makeAddr("alice");
    bytes32 testKey;
    BlockNumber deployBlock;

    function setUp() public {
        registry = new EntityRegistry();
        deployBlock = currentBlock();

        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        Entity.Operation[] memory ops = new Entity.Operation[](1);
        ops[0] = Entity.Operation({
            operationType: Entity.CREATE,
            entityKey: bytes32(0),
            payload: "hello",
            contentType: encodeMime128("text/plain"),
            attributes: attrs,
            expiresAt: currentBlock() + BlockNumber.wrap(1000),
            newOwner: address(0)
        });

        vm.prank(alice);
        registry.execute(ops);

        testKey = registry.entityKey(alice, 0);
    }

    function test_changeSetHash() public view {
        assertTrue(registry.changeSetHash() != bytes32(0));
    }

    function test_changeSetHashAtBlock() public view {
        assertTrue(registry.changeSetHashAtBlock(deployBlock) != bytes32(0));
    }

    function test_changeSetHashAtTx() public view {
        assertTrue(registry.changeSetHashAtTx(deployBlock, 0) != bytes32(0));
    }

    function test_changeSetHashAtOp() public view {
        assertTrue(registry.changeSetHashAtOp(deployBlock, 0, 0) != bytes32(0));
    }

    function test_entityKey() public view {
        bytes32 key = registry.entityKey(alice, 0);
        assertEq(key, testKey);
    }

    function test_genesisBlock() public view {
        assertEq(BlockNumber.unwrap(registry.genesisBlock()), BlockNumber.unwrap(deployBlock));
    }

    function test_headBlock() public view {
        assertEq(BlockNumber.unwrap(registry.headBlock()), BlockNumber.unwrap(deployBlock));
    }

    function test_getBlockNode() public view {
        Entity.BlockNode memory node = registry.getBlockNode(deployBlock);
        assertEq(node.txCount, 1);
    }

    function test_txOpCount() public view {
        assertEq(registry.txOpCount(deployBlock, 0), 1);
    }

    function test_commitment() public view {
        Entity.Commitment memory c = registry.commitment(testKey);
        assertEq(c.owner, alice);
        assertEq(c.creator, alice);
    }

    function test_nonces() public view {
        assertEq(registry.nonces(alice), 1);
        assertEq(registry.nonces(address(0)), 0);
    }
}
