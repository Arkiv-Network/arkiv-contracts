// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../src/BlockNumber.sol";
import {Base} from "../utils/Base.t.sol";
import {EntityHashing, OpKey, TxKey} from "../../src/EntityHashing.sol";

contract PackTest is Base {
    // =========================================================================
    // opKey
    // =========================================================================

    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_opKey_deterministic() public pure {
        // GIVEN the same inputs
        // WHEN packing twice
        // THEN the results are equal
        assertEq(
            OpKey.unwrap(EntityHashing.opKey(BlockNumber.wrap(1), 2, 3)),
            OpKey.unwrap(EntityHashing.opKey(BlockNumber.wrap(1), 2, 3))
        );
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different keys
    // -------------------------------------------------------------------------

    function test_opKey_differentBlock_differs() public pure {
        assertNotEq(
            OpKey.unwrap(EntityHashing.opKey(BlockNumber.wrap(1), 1, 1)),
            OpKey.unwrap(EntityHashing.opKey(BlockNumber.wrap(2), 1, 1))
        );
    }

    function test_opKey_differentTx_differs() public pure {
        assertNotEq(
            OpKey.unwrap(EntityHashing.opKey(BlockNumber.wrap(1), 1, 1)),
            OpKey.unwrap(EntityHashing.opKey(BlockNumber.wrap(1), 2, 1))
        );
    }

    function test_opKey_differentOp_differs() public pure {
        assertNotEq(
            OpKey.unwrap(EntityHashing.opKey(BlockNumber.wrap(1), 1, 1)),
            OpKey.unwrap(EntityHashing.opKey(BlockNumber.wrap(1), 1, 2))
        );
    }

    // -------------------------------------------------------------------------
    // Bit layout — manual verification
    // -------------------------------------------------------------------------

    function test_opKey_layout() public pure {
        // GIVEN known inputs
        BlockNumber blockNumber = BlockNumber.wrap(0xAB);
        uint32 txSeq = 0xCD;
        uint32 opSeq = 0xEF;

        // WHEN packing
        uint256 packed = OpKey.unwrap(EntityHashing.opKey(blockNumber, txSeq, opSeq));

        // THEN it matches the expected bit layout: block << 64 | tx << 32 | op
        uint256 expected = (0xAB << 64) | (uint256(0xCD) << 32) | 0xEF;
        assertEq(packed, expected);
    }

    function test_opKey_zeroInputs() public pure {
        // GIVEN all zeros
        // THEN the packed key is zero
        assertEq(OpKey.unwrap(EntityHashing.opKey(BlockNumber.wrap(0), 0, 0)), 0);
    }

    // -------------------------------------------------------------------------
    // Assembly correctness — fuzz
    // -------------------------------------------------------------------------

    function test_opKey_fuzz(uint32 rawBlock, uint32 txSeq, uint32 opSeq) public pure {
        // GIVEN arbitrary inputs
        BlockNumber blockNumber = BlockNumber.wrap(rawBlock);

        // WHEN packing via the library
        uint256 actual = OpKey.unwrap(EntityHashing.opKey(blockNumber, txSeq, opSeq));

        // THEN it matches the manual bit operation
        uint256 expected = (uint256(rawBlock) << 64) | (uint256(txSeq) << 32) | opSeq;
        assertEq(actual, expected);
    }

    // -------------------------------------------------------------------------
    // opKey builds on txKey
    // -------------------------------------------------------------------------

    function test_opKey_extendsTxKey(uint32 rawBlock, uint32 txSeq, uint32 opSeq) public pure {
        // GIVEN an opKey and its corresponding txKey
        BlockNumber blockNumber = BlockNumber.wrap(rawBlock);
        uint256 ok = OpKey.unwrap(EntityHashing.opKey(blockNumber, txSeq, opSeq));
        uint256 tk = TxKey.unwrap(EntityHashing.txKey(blockNumber, txSeq));

        // THEN the upper bits of opKey equal txKey shifted left by 32
        assertEq(ok >> 32, tk);
    }

    // =========================================================================
    // txKey
    // =========================================================================

    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_txKey_deterministic() public pure {
        // GIVEN the same inputs
        // WHEN packing twice
        // THEN the results are equal
        assertEq(
            TxKey.unwrap(EntityHashing.txKey(BlockNumber.wrap(1), 2)),
            TxKey.unwrap(EntityHashing.txKey(BlockNumber.wrap(1), 2))
        );
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different keys
    // -------------------------------------------------------------------------

    function test_txKey_differentBlock_differs() public pure {
        assertNotEq(
            TxKey.unwrap(EntityHashing.txKey(BlockNumber.wrap(1), 1)),
            TxKey.unwrap(EntityHashing.txKey(BlockNumber.wrap(2), 1))
        );
    }

    function test_txKey_differentTx_differs() public pure {
        assertNotEq(
            TxKey.unwrap(EntityHashing.txKey(BlockNumber.wrap(1), 1)),
            TxKey.unwrap(EntityHashing.txKey(BlockNumber.wrap(1), 2))
        );
    }

    // -------------------------------------------------------------------------
    // Bit layout — manual verification
    // -------------------------------------------------------------------------

    function test_txKey_layout() public pure {
        // GIVEN known inputs
        BlockNumber blockNumber = BlockNumber.wrap(0xAB);
        uint32 txSeq = 0xCD;

        // WHEN packing
        uint256 packed = TxKey.unwrap(EntityHashing.txKey(blockNumber, txSeq));

        // THEN it matches the expected bit layout: block << 32 | tx
        uint256 expected = (0xAB << 32) | 0xCD;
        assertEq(packed, expected);
    }

    function test_txKey_zeroInputs() public pure {
        // GIVEN all zeros
        // THEN the packed key is zero
        assertEq(TxKey.unwrap(EntityHashing.txKey(BlockNumber.wrap(0), 0)), 0);
    }

    // -------------------------------------------------------------------------
    // Assembly correctness — fuzz
    // -------------------------------------------------------------------------

    function test_txKey_fuzz(uint32 rawBlock, uint32 txSeq) public pure {
        // GIVEN arbitrary inputs
        BlockNumber blockNumber = BlockNumber.wrap(rawBlock);

        // WHEN packing via the library
        uint256 actual = TxKey.unwrap(EntityHashing.txKey(blockNumber, txSeq));

        // THEN it matches the manual bit operation
        uint256 expected = (uint256(rawBlock) << 32) | txSeq;
        assertEq(actual, expected);
    }
}
