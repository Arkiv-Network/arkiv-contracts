// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Entity} from "../../../src/Entity.sol";

contract ChainOpTest is Test {
    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_chainOperationHash_deterministic() public pure {
        // GIVEN the same inputs
        bytes32 prev = keccak256("prev");
        bytes32 key = keccak256("key");
        bytes32 entityHash = keccak256("entity");

        // WHEN computing chainOperationHash twice
        bytes32 hashA = Entity.chainOperationHash(prev, Entity.CREATE, key, entityHash);
        bytes32 hashB = Entity.chainOperationHash(prev, Entity.CREATE, key, entityHash);

        // THEN the hashes are equal
        assertEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_chainOperationHash_differentPrev_differs() public pure {
        // GIVEN two calls differing only in prev
        bytes32 key = keccak256("key");
        bytes32 entityHash = keccak256("entity");

        bytes32 hashA = Entity.chainOperationHash(keccak256("prev1"), Entity.CREATE, key, entityHash);
        bytes32 hashB = Entity.chainOperationHash(keccak256("prev2"), Entity.CREATE, key, entityHash);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_chainOperationHash_differentOpType_differs() public pure {
        // GIVEN two calls differing only in opType
        bytes32 prev = keccak256("prev");
        bytes32 key = keccak256("key");
        bytes32 entityHash = keccak256("entity");

        bytes32 hashA = Entity.chainOperationHash(prev, Entity.CREATE, key, entityHash);
        bytes32 hashB = Entity.chainOperationHash(prev, Entity.DELETE, key, entityHash);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_chainOperationHash_differentKey_differs() public pure {
        // GIVEN two calls differing only in key
        bytes32 prev = keccak256("prev");
        bytes32 entityHash = keccak256("entity");

        bytes32 hashA = Entity.chainOperationHash(prev, Entity.CREATE, keccak256("k1"), entityHash);
        bytes32 hashB = Entity.chainOperationHash(prev, Entity.CREATE, keccak256("k2"), entityHash);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_chainOperationHash_differentEntityHash_differs() public pure {
        // GIVEN two calls differing only in entityHash
        bytes32 prev = keccak256("prev");
        bytes32 key = keccak256("key");

        bytes32 hashA = Entity.chainOperationHash(prev, Entity.CREATE, key, keccak256("e1"));
        bytes32 hashB = Entity.chainOperationHash(prev, Entity.CREATE, key, keccak256("e2"));

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Chaining — order matters
    // -------------------------------------------------------------------------

    function test_chainOperationHash_orderMatters() public pure {
        // GIVEN two ops chained in different order
        bytes32 keyA = keccak256("a");
        bytes32 hashA = keccak256("ha");
        bytes32 keyB = keccak256("b");
        bytes32 hashB = keccak256("hb");

        bytes32 chainAB = Entity.chainOperationHash(
            Entity.chainOperationHash(bytes32(0), Entity.CREATE, keyA, hashA), Entity.CREATE, keyB, hashB
        );

        bytes32 chainBA = Entity.chainOperationHash(
            Entity.chainOperationHash(bytes32(0), Entity.CREATE, keyB, hashB), Entity.CREATE, keyA, hashA
        );

        // THEN the resulting hashes differ
        assertNotEq(chainAB, chainBA);
    }

    function test_chainOperationHash_fromZero_nonZero() public pure {
        // GIVEN chaining from a zero prev hash (initial state)
        bytes32 key = keccak256("key");
        bytes32 entityHash = keccak256("entity");

        // WHEN computing
        bytes32 result = Entity.chainOperationHash(bytes32(0), Entity.CREATE, key, entityHash);

        // THEN the result is non-zero
        assertNotEq(result, bytes32(0));
    }

    // -------------------------------------------------------------------------
    // All OpType variants produce distinct hashes
    // -------------------------------------------------------------------------

    function test_chainOperationHash_allOpTypes_distinct() public pure {
        // GIVEN the same prev, key, entityHash but every OpType
        bytes32 prev = keccak256("prev");
        bytes32 key = keccak256("key");
        bytes32 entityHash = keccak256("entity");

        bytes32 hCreate = Entity.chainOperationHash(prev, Entity.CREATE, key, entityHash);
        bytes32 hUpdate = Entity.chainOperationHash(prev, Entity.UPDATE, key, entityHash);
        bytes32 hExtend = Entity.chainOperationHash(prev, Entity.EXTEND, key, entityHash);
        bytes32 hTransfer = Entity.chainOperationHash(prev, Entity.TRANSFER, key, entityHash);
        bytes32 hDelete = Entity.chainOperationHash(prev, Entity.DELETE, key, entityHash);
        bytes32 hExpire = Entity.chainOperationHash(prev, Entity.EXPIRE, key, entityHash);

        // THEN all 6 are distinct
        bytes32[6] memory hashes = [hCreate, hUpdate, hExtend, hTransfer, hDelete, hExpire];
        for (uint256 i = 0; i < 6; i++) {
            for (uint256 j = i + 1; j < 6; j++) {
                assertNotEq(hashes[i], hashes[j]);
            }
        }
    }

    // -------------------------------------------------------------------------
    // Assembly correctness — fuzz against pure-Solidity reference
    // -------------------------------------------------------------------------

    function test_chainOperationHash_fuzz(bytes32 prev, uint8 rawOpType, bytes32 key, bytes32 entityHash_) public pure {
        // GIVEN arbitrary inputs, bound opType to valid range
        rawOpType = uint8(bound(rawOpType, 0, 5));
        // WHEN computing via the assembly implementation
        bytes32 actual = Entity.chainOperationHash(prev, rawOpType, key, entityHash_);

        // THEN it matches the pure-Solidity reference
        bytes32 expected = keccak256(abi.encodePacked(prev, rawOpType, key, entityHash_));
        assertEq(actual, expected);
    }
}
