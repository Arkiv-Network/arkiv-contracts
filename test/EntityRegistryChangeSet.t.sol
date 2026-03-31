// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {EntityRegistry} from "../src/EntityRegistry.sol";

/// @dev Harness that exposes internal functions for testing.
contract EntityRegistryHarness is EntityRegistry {
    function exposed_accumulateChangeSet(OpType opType, bytes32 _entityKey, bytes32 _entityHash) external {
        _accumulateChangeSet(opType, _entityKey, _entityHash);
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

    function test_initialState_zero() public view {
        // GIVEN a freshly deployed registry
        // THEN changeSetHash is zero
        assertEq(registry.changeSetHash(), bytes32(0));
    }

    // -------------------------------------------------------------------------
    // Single mutation
    // -------------------------------------------------------------------------

    function test_singleOp_producesNonZeroHash() public {
        // GIVEN a fresh registry
        bytes32 key = keccak256("entity1");
        bytes32 hash = keccak256("hash1");

        // WHEN a single CREATE op is recorded
        registry.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, key, hash);

        // THEN changeSetHash is non-zero and matches the expected chain
        bytes32 expected = keccak256(abi.encodePacked(bytes32(0), EntityRegistry.OpType.CREATE, key, hash));
        assertEq(registry.changeSetHash(), expected);
    }

    // -------------------------------------------------------------------------
    // Chaining — multiple ops
    // -------------------------------------------------------------------------

    function test_multipleOps_chainCorrectly() public {
        // GIVEN two mutations
        bytes32 key1 = keccak256("entity1");
        bytes32 hash1 = keccak256("hash1");
        bytes32 key2 = keccak256("entity2");
        bytes32 hash2 = keccak256("hash2");

        registry.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, key1, hash1);
        registry.exposed_accumulateChangeSet(EntityRegistry.OpType.UPDATE, key2, hash2);

        // THEN changeSetHash chains both mutations sequentially
        bytes32 after1 = keccak256(abi.encodePacked(bytes32(0), EntityRegistry.OpType.CREATE, key1, hash1));
        bytes32 after2 = keccak256(abi.encodePacked(after1, EntityRegistry.OpType.UPDATE, key2, hash2));
        assertEq(registry.changeSetHash(), after2);
    }

    // -------------------------------------------------------------------------
    // Cross-block continuity
    // -------------------------------------------------------------------------

    function test_crossBlock_chainsWithoutReset() public {
        // GIVEN a mutation in block N
        bytes32 key1 = keccak256("entity1");
        bytes32 hash1 = keccak256("hash1");
        registry.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, key1, hash1);
        bytes32 afterBlock1 = registry.changeSetHash();

        // WHEN we advance to a new block and record another mutation
        vm.roll(block.number + 1);
        bytes32 key2 = keccak256("entity2");
        bytes32 hash2 = keccak256("hash2");
        registry.exposed_accumulateChangeSet(EntityRegistry.OpType.DELETE, key2, hash2);

        // THEN the hash chains continuously — no reset at block boundary
        bytes32 expected = keccak256(abi.encodePacked(afterBlock1, EntityRegistry.OpType.DELETE, key2, hash2));
        assertEq(registry.changeSetHash(), expected);
    }

    function test_threeBlocks_continuousChain() public {
        // Block 1
        registry.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, keccak256("e1"), keccak256("h1"));

        // Block 2
        vm.roll(block.number + 1);
        registry.exposed_accumulateChangeSet(EntityRegistry.OpType.UPDATE, keccak256("e2"), keccak256("h2"));
        bytes32 after2 = registry.changeSetHash();

        // Block 3
        vm.roll(block.number + 1);
        registry.exposed_accumulateChangeSet(EntityRegistry.OpType.DELETE, keccak256("e3"), keccak256("h3"));

        // THEN the final hash chains all three ops regardless of block boundaries
        bytes32 expected =
            keccak256(abi.encodePacked(after2, EntityRegistry.OpType.DELETE, keccak256("e3"), keccak256("h3")));
        assertEq(registry.changeSetHash(), expected);
    }

    // -------------------------------------------------------------------------
    // Block gap — no special handling needed
    // -------------------------------------------------------------------------

    function test_blockGap_chainsNormally() public {
        // GIVEN a mutation in block 1
        registry.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, keccak256("e1"), keccak256("h1"));
        bytes32 afterFirst = registry.changeSetHash();

        // WHEN 100 blocks pass with no mutations, then another mutation
        vm.roll(block.number + 100);
        registry.exposed_accumulateChangeSet(EntityRegistry.OpType.EXPIRE, keccak256("e2"), keccak256("h2"));

        // THEN the hash just chains — block gaps are invisible
        bytes32 expected =
            keccak256(abi.encodePacked(afterFirst, EntityRegistry.OpType.EXPIRE, keccak256("e2"), keccak256("h2")));
        assertEq(registry.changeSetHash(), expected);
    }

    // -------------------------------------------------------------------------
    // Op type affects the hash
    // -------------------------------------------------------------------------

    function test_differentOpType_differentHash() public {
        // GIVEN the same key and hash but different op types
        bytes32 key = keccak256("entity");
        bytes32 hash = keccak256("hash");

        EntityRegistryHarness r1 = new EntityRegistryHarness();
        EntityRegistryHarness r2 = new EntityRegistryHarness();

        r1.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, key, hash);
        r2.exposed_accumulateChangeSet(EntityRegistry.OpType.DELETE, key, hash);

        // THEN the resulting hashes differ
        assertNotEq(r1.changeSetHash(), r2.changeSetHash());
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

        r1.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, keyA, hashA);
        r1.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, keyB, hashB);

        r2.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, keyB, hashB);
        r2.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, keyA, hashA);

        // THEN the resulting hashes differ
        assertNotEq(r1.changeSetHash(), r2.changeSetHash());
    }

    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_sameOps_sameHash() public {
        // GIVEN two registries with identical op sequences
        EntityRegistryHarness r1 = new EntityRegistryHarness();
        EntityRegistryHarness r2 = new EntityRegistryHarness();

        bytes32 key = keccak256("entity");
        bytes32 hash = keccak256("hash");

        r1.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, key, hash);
        r2.exposed_accumulateChangeSet(EntityRegistry.OpType.CREATE, key, hash);

        // THEN their hashes are identical
        assertEq(r1.changeSetHash(), r2.changeSetHash());
    }
}
