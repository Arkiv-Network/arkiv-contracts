// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {EntityRegistry} from "../src/EntityRegistry.sol";

/// @dev Harness that exposes internal functions for testing.
contract EntityRegistryHarness is EntityRegistry {
    function exposed_op(Op op, bytes32 _entityKey, bytes32 _entityHash) external {
        _op(op, _entityKey, _entityHash);
    }
}

contract EntityRegistryChangeSetTest is Test {
    EntityRegistryHarness registry;

    function setUp() public {
        registry = new EntityRegistryHarness();
    }

    // -------------------------------------------------------------------------
    // Initial state
    // -------------------------------------------------------------------------

    function test_initialState_allZero() public view {
        // GIVEN a freshly deployed registry
        // THEN all change set state is zero
        assertEq(registry.currentBlockChangeSetHash(), bytes32(0));
        assertEq(registry.cumulativeChangeSetHash(), bytes32(0));
        assertEq(registry.lastMutationBlock(), 0);
    }

    // -------------------------------------------------------------------------
    // Single mutation
    // -------------------------------------------------------------------------

    function test_singleOp_updatesCurrentBlockHash() public {
        // GIVEN a fresh registry
        bytes32 key = keccak256("entity1");
        bytes32 hash = keccak256("hash1");

        // WHEN a single CREATE op is recorded
        registry.exposed_op(EntityRegistry.Op.CREATE, key, hash);

        // THEN currentBlockChangeSetHash is non-zero
        assertNotEq(registry.currentBlockChangeSetHash(), bytes32(0));

        // AND it matches the expected chained hash
        bytes32 expected = keccak256(abi.encodePacked(bytes32(0), EntityRegistry.Op.CREATE, key, hash));
        assertEq(registry.currentBlockChangeSetHash(), expected);

        // AND lastMutationBlock is the current block
        assertEq(registry.lastMutationBlock(), block.number);

        // AND cumulativeChangeSetHash is still zero (no block boundary crossed)
        assertEq(registry.cumulativeChangeSetHash(), bytes32(0));
    }

    // -------------------------------------------------------------------------
    // Multiple mutations in the same block
    // -------------------------------------------------------------------------

    function test_multipleOps_sameBlock_chainsCorrectly() public {
        // GIVEN two mutations in the same block
        bytes32 key1 = keccak256("entity1");
        bytes32 hash1 = keccak256("hash1");
        bytes32 key2 = keccak256("entity2");
        bytes32 hash2 = keccak256("hash2");

        registry.exposed_op(EntityRegistry.Op.CREATE, key1, hash1);
        registry.exposed_op(EntityRegistry.Op.UPDATE, key2, hash2);

        // THEN currentBlockChangeSetHash chains both mutations
        bytes32 after1 = keccak256(abi.encodePacked(bytes32(0), EntityRegistry.Op.CREATE, key1, hash1));
        bytes32 after2 = keccak256(abi.encodePacked(after1, EntityRegistry.Op.UPDATE, key2, hash2));
        assertEq(registry.currentBlockChangeSetHash(), after2);

        // AND cumulativeChangeSetHash is still zero (still in the same block)
        assertEq(registry.cumulativeChangeSetHash(), bytes32(0));
    }

    // -------------------------------------------------------------------------
    // Block boundary — finalization
    // -------------------------------------------------------------------------

    function test_newBlock_finalizesPreviousBlock() public {
        // GIVEN a mutation in block N
        bytes32 key1 = keccak256("entity1");
        bytes32 hash1 = keccak256("hash1");
        registry.exposed_op(EntityRegistry.Op.CREATE, key1, hash1);

        bytes32 block1Hash = registry.currentBlockChangeSetHash();
        uint256 block1 = block.number;

        // WHEN we advance to a new block and record another mutation
        vm.roll(block.number + 1);
        bytes32 key2 = keccak256("entity2");
        bytes32 hash2 = keccak256("hash2");
        registry.exposed_op(EntityRegistry.Op.DELETE, key2, hash2);

        // THEN cumulativeChangeSetHash includes block1's finalized hash
        bytes32 expectedCumulative = keccak256(abi.encodePacked(bytes32(0), block1, block1Hash));
        assertEq(registry.cumulativeChangeSetHash(), expectedCumulative);

        // AND currentBlockChangeSetHash is the new block's hash (reset + new mutation)
        bytes32 expectedCurrent = keccak256(abi.encodePacked(bytes32(0), EntityRegistry.Op.DELETE, key2, hash2));
        assertEq(registry.currentBlockChangeSetHash(), expectedCurrent);

        // AND lastMutationBlock is the new block
        assertEq(registry.lastMutationBlock(), block.number);
    }

    function test_newBlock_emitsChangeSetHashFinalized() public {
        // GIVEN a mutation in block N
        bytes32 key1 = keccak256("entity1");
        bytes32 hash1 = keccak256("hash1");
        registry.exposed_op(EntityRegistry.Op.CREATE, key1, hash1);

        bytes32 block1Hash = registry.currentBlockChangeSetHash();
        uint256 block1 = block.number;
        bytes32 expectedCumulative = keccak256(abi.encodePacked(bytes32(0), block1, block1Hash));

        // WHEN we advance and record a mutation
        vm.roll(block.number + 1);

        // THEN the finalization event is emitted
        vm.expectEmit(true, false, false, true);
        emit EntityRegistry.ChangeSetHashFinalized(block1, block1Hash, expectedCumulative);

        registry.exposed_op(EntityRegistry.Op.UPDATE, keccak256("entity2"), keccak256("hash2"));
    }

    // -------------------------------------------------------------------------
    // Multiple block boundaries
    // -------------------------------------------------------------------------

    function test_threeBlocks_cumulativeChains() public {
        // Block 1: one CREATE
        bytes32 key1 = keccak256("e1");
        bytes32 hash1 = keccak256("h1");
        registry.exposed_op(EntityRegistry.Op.CREATE, key1, hash1);
        bytes32 block1Hash = registry.currentBlockChangeSetHash();
        uint256 block1 = block.number;

        // Block 2: one UPDATE
        vm.roll(block.number + 1);
        bytes32 key2 = keccak256("e2");
        bytes32 hash2 = keccak256("h2");
        registry.exposed_op(EntityRegistry.Op.UPDATE, key2, hash2);
        bytes32 block2Hash = registry.currentBlockChangeSetHash();
        uint256 block2 = block.number;

        bytes32 cumAfter1 = keccak256(abi.encodePacked(bytes32(0), block1, block1Hash));

        // Block 3: one DELETE
        vm.roll(block.number + 1);
        bytes32 key3 = keccak256("e3");
        bytes32 hash3 = keccak256("h3");
        registry.exposed_op(EntityRegistry.Op.DELETE, key3, hash3);

        // THEN cumulative hash chains block1 → block2
        bytes32 cumAfter2 = keccak256(abi.encodePacked(cumAfter1, block2, block2Hash));
        assertEq(registry.cumulativeChangeSetHash(), cumAfter2);
    }

    // -------------------------------------------------------------------------
    // Gap in blocks (no mutations for several blocks)
    // -------------------------------------------------------------------------

    function test_blockGap_finalizesCorrectly() public {
        // GIVEN a mutation in block 1
        bytes32 key1 = keccak256("e1");
        bytes32 hash1 = keccak256("h1");
        registry.exposed_op(EntityRegistry.Op.CREATE, key1, hash1);
        bytes32 block1Hash = registry.currentBlockChangeSetHash();
        uint256 block1 = block.number;

        // WHEN 100 blocks pass with no mutations, then a mutation in block 101
        vm.roll(block.number + 100);
        registry.exposed_op(EntityRegistry.Op.EXPIRE, keccak256("e2"), keccak256("h2"));

        // THEN block1's hash is finalized into the cumulative hash
        bytes32 expectedCumulative = keccak256(abi.encodePacked(bytes32(0), block1, block1Hash));
        assertEq(registry.cumulativeChangeSetHash(), expectedCumulative);

        // AND lastMutationBlock jumped to the current block
        assertEq(registry.lastMutationBlock(), block.number);
    }

    // -------------------------------------------------------------------------
    // Op type affects the hash
    // -------------------------------------------------------------------------

    function test_differentOpType_differentHash() public {
        // GIVEN the same key and hash but different op types
        bytes32 key = keccak256("entity");
        bytes32 hash = keccak256("hash");

        // Deploy two registries to isolate state
        EntityRegistryHarness r1 = new EntityRegistryHarness();
        EntityRegistryHarness r2 = new EntityRegistryHarness();

        r1.exposed_op(EntityRegistry.Op.CREATE, key, hash);
        r2.exposed_op(EntityRegistry.Op.DELETE, key, hash);

        // THEN the resulting hashes differ
        assertNotEq(r1.currentBlockChangeSetHash(), r2.currentBlockChangeSetHash());
    }

    // -------------------------------------------------------------------------
    // Ordering matters
    // -------------------------------------------------------------------------

    function test_orderMatters() public {
        // GIVEN two mutations applied in different order
        bytes32 keyA = keccak256("a");
        bytes32 hashA = keccak256("ha");
        bytes32 keyB = keccak256("b");
        bytes32 hashB = keccak256("hb");

        EntityRegistryHarness r1 = new EntityRegistryHarness();
        EntityRegistryHarness r2 = new EntityRegistryHarness();

        r1.exposed_op(EntityRegistry.Op.CREATE, keyA, hashA);
        r1.exposed_op(EntityRegistry.Op.CREATE, keyB, hashB);

        r2.exposed_op(EntityRegistry.Op.CREATE, keyB, hashB);
        r2.exposed_op(EntityRegistry.Op.CREATE, keyA, hashA);

        // THEN the resulting hashes differ
        assertNotEq(r1.currentBlockChangeSetHash(), r2.currentBlockChangeSetHash());
    }
}
