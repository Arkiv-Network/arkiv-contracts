// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../utils/Base.t.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";

contract PackTest is Base {
    // =========================================================================
    // packHashKey
    // =========================================================================

    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_packHashKey_deterministic() public pure {
        // GIVEN the same inputs
        // WHEN packing twice
        // THEN the results are equal
        assertEq(EntityHashing.packHashKey(1, 2, 3), EntityHashing.packHashKey(1, 2, 3));
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different keys
    // -------------------------------------------------------------------------

    function test_packHashKey_differentBlock_differs() public pure {
        assertNotEq(EntityHashing.packHashKey(1, 1, 1), EntityHashing.packHashKey(2, 1, 1));
    }

    function test_packHashKey_differentTx_differs() public pure {
        assertNotEq(EntityHashing.packHashKey(1, 1, 1), EntityHashing.packHashKey(1, 2, 1));
    }

    function test_packHashKey_differentOp_differs() public pure {
        assertNotEq(EntityHashing.packHashKey(1, 1, 1), EntityHashing.packHashKey(1, 1, 2));
    }

    // -------------------------------------------------------------------------
    // Bit layout — manual verification
    // -------------------------------------------------------------------------

    function test_packHashKey_layout() public pure {
        // GIVEN known inputs
        uint256 blockNumber = 0xAB;
        uint32 txSeq = 0xCD;
        uint32 opSeq = 0xEF;

        // WHEN packing
        uint256 packed = EntityHashing.packHashKey(blockNumber, txSeq, opSeq);

        // THEN it matches the expected bit layout: block << 64 | tx << 32 | op
        uint256 expected = (0xAB << 64) | (uint256(0xCD) << 32) | 0xEF;
        assertEq(packed, expected);
    }

    function test_packHashKey_zeroInputs() public pure {
        // GIVEN all zeros
        // THEN the packed key is zero
        assertEq(EntityHashing.packHashKey(0, 0, 0), 0);
    }

    // -------------------------------------------------------------------------
    // Assembly correctness — fuzz
    // -------------------------------------------------------------------------

    function test_packHashKey_fuzz(uint256 blockNumber, uint32 txSeq, uint32 opSeq) public pure {
        // GIVEN arbitrary inputs
        // WHEN packing via the library
        uint256 actual = EntityHashing.packHashKey(blockNumber, txSeq, opSeq);

        // THEN it matches the manual bit operation
        uint256 expected = (blockNumber << 64) | (uint256(txSeq) << 32) | opSeq;
        assertEq(actual, expected);
    }

    // =========================================================================
    // packTxKey
    // =========================================================================

    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_packTxKey_deterministic() public pure {
        // GIVEN the same inputs
        // WHEN packing twice
        // THEN the results are equal
        assertEq(EntityHashing.packTxKey(1, 2), EntityHashing.packTxKey(1, 2));
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different keys
    // -------------------------------------------------------------------------

    function test_packTxKey_differentBlock_differs() public pure {
        assertNotEq(EntityHashing.packTxKey(1, 1), EntityHashing.packTxKey(2, 1));
    }

    function test_packTxKey_differentTx_differs() public pure {
        assertNotEq(EntityHashing.packTxKey(1, 1), EntityHashing.packTxKey(1, 2));
    }

    // -------------------------------------------------------------------------
    // Bit layout — manual verification
    // -------------------------------------------------------------------------

    function test_packTxKey_layout() public pure {
        // GIVEN known inputs
        uint256 blockNumber = 0xAB;
        uint32 txSeq = 0xCD;

        // WHEN packing
        uint256 packed = EntityHashing.packTxKey(blockNumber, txSeq);

        // THEN it matches the expected bit layout: block << 32 | tx
        uint256 expected = (0xAB << 32) | 0xCD;
        assertEq(packed, expected);
    }

    function test_packTxKey_zeroInputs() public pure {
        // GIVEN all zeros
        // THEN the packed key is zero
        assertEq(EntityHashing.packTxKey(0, 0), 0);
    }

    // -------------------------------------------------------------------------
    // Assembly correctness — fuzz
    // -------------------------------------------------------------------------

    function test_packTxKey_fuzz(uint256 blockNumber, uint32 txSeq) public pure {
        // GIVEN arbitrary inputs
        // WHEN packing via the library
        uint256 actual = EntityHashing.packTxKey(blockNumber, txSeq);

        // THEN it matches the manual bit operation
        uint256 expected = (blockNumber << 32) | txSeq;
        assertEq(actual, expected);
    }
}
