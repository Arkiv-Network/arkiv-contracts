// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../utils/Base.t.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";

contract ChainOpTest is Base {
    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_chainOp_deterministic() public pure {
        // GIVEN the same inputs
        bytes32 prev = keccak256("prev");
        bytes32 key = keccak256("key");
        bytes32 entityHash = keccak256("entity");

        // WHEN computing chainOp twice
        bytes32 hashA = EntityHashing.chainOp(prev, EntityHashing.CREATE, key, entityHash);
        bytes32 hashB = EntityHashing.chainOp(prev, EntityHashing.CREATE, key, entityHash);

        // THEN the hashes are equal
        assertEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_chainOp_differentPrev_differs() public pure {
        // GIVEN two calls differing only in prev
        bytes32 key = keccak256("key");
        bytes32 entityHash = keccak256("entity");

        bytes32 hashA = EntityHashing.chainOp(keccak256("prev1"), EntityHashing.CREATE, key, entityHash);
        bytes32 hashB = EntityHashing.chainOp(keccak256("prev2"), EntityHashing.CREATE, key, entityHash);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_chainOp_differentOpType_differs() public pure {
        // GIVEN two calls differing only in opType
        bytes32 prev = keccak256("prev");
        bytes32 key = keccak256("key");
        bytes32 entityHash = keccak256("entity");

        bytes32 hashA = EntityHashing.chainOp(prev, EntityHashing.CREATE, key, entityHash);
        bytes32 hashB = EntityHashing.chainOp(prev, EntityHashing.DELETE, key, entityHash);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_chainOp_differentKey_differs() public pure {
        // GIVEN two calls differing only in key
        bytes32 prev = keccak256("prev");
        bytes32 entityHash = keccak256("entity");

        bytes32 hashA = EntityHashing.chainOp(prev, EntityHashing.CREATE, keccak256("k1"), entityHash);
        bytes32 hashB = EntityHashing.chainOp(prev, EntityHashing.CREATE, keccak256("k2"), entityHash);

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    function test_chainOp_differentEntityHash_differs() public pure {
        // GIVEN two calls differing only in entityHash
        bytes32 prev = keccak256("prev");
        bytes32 key = keccak256("key");

        bytes32 hashA = EntityHashing.chainOp(prev, EntityHashing.CREATE, key, keccak256("e1"));
        bytes32 hashB = EntityHashing.chainOp(prev, EntityHashing.CREATE, key, keccak256("e2"));

        // THEN the hashes differ
        assertNotEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Chaining — order matters
    // -------------------------------------------------------------------------

    function test_chainOp_orderMatters() public pure {
        // GIVEN two ops chained in different order
        bytes32 keyA = keccak256("a");
        bytes32 hashA = keccak256("ha");
        bytes32 keyB = keccak256("b");
        bytes32 hashB = keccak256("hb");

        bytes32 chainAB = EntityHashing.chainOp(
            EntityHashing.chainOp(bytes32(0), EntityHashing.CREATE, keyA, hashA), EntityHashing.CREATE, keyB, hashB
        );

        bytes32 chainBA = EntityHashing.chainOp(
            EntityHashing.chainOp(bytes32(0), EntityHashing.CREATE, keyB, hashB), EntityHashing.CREATE, keyA, hashA
        );

        // THEN the resulting hashes differ
        assertNotEq(chainAB, chainBA);
    }

    function test_chainOp_fromZero_nonZero() public pure {
        // GIVEN chaining from a zero prev hash (initial state)
        bytes32 key = keccak256("key");
        bytes32 entityHash = keccak256("entity");

        // WHEN computing
        bytes32 result = EntityHashing.chainOp(bytes32(0), EntityHashing.CREATE, key, entityHash);

        // THEN the result is non-zero
        assertNotEq(result, bytes32(0));
    }

    // -------------------------------------------------------------------------
    // All OpType variants produce distinct hashes
    // -------------------------------------------------------------------------

    function test_chainOp_allOpTypes_distinct() public pure {
        // GIVEN the same prev, key, entityHash but every OpType
        bytes32 prev = keccak256("prev");
        bytes32 key = keccak256("key");
        bytes32 entityHash = keccak256("entity");

        bytes32 hCreate = EntityHashing.chainOp(prev, EntityHashing.CREATE, key, entityHash);
        bytes32 hUpdate = EntityHashing.chainOp(prev, EntityHashing.UPDATE, key, entityHash);
        bytes32 hExtend = EntityHashing.chainOp(prev, EntityHashing.EXTEND, key, entityHash);
        bytes32 hTransfer = EntityHashing.chainOp(prev, EntityHashing.TRANSFER, key, entityHash);
        bytes32 hDelete = EntityHashing.chainOp(prev, EntityHashing.DELETE, key, entityHash);
        bytes32 hExpire = EntityHashing.chainOp(prev, EntityHashing.EXPIRE, key, entityHash);

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

    function test_chainOp_fuzz(bytes32 prev, uint8 rawOpType, bytes32 key, bytes32 entityHash_) public pure {
        // GIVEN arbitrary inputs, bound opType to valid range
        rawOpType = uint8(bound(rawOpType, 0, 5));
        // WHEN computing via the assembly implementation
        bytes32 actual = EntityHashing.chainOp(prev, rawOpType, key, entityHash_);

        // THEN it matches the pure-Solidity reference
        bytes32 expected = keccak256(abi.encodePacked(prev, rawOpType, key, entityHash_));
        assertEq(actual, expected);
    }
}
