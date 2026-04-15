// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Entity, OperationKey, TransactionKey} from "../../../src/Entity.sol";

contract PackTest is Test {
    // =========================================================================
    // operationKey
    // =========================================================================

    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_operationKey_deterministic() public pure {
        // GIVEN the same inputs
        // WHEN packing twice
        // THEN the results are equal
        assertEq(
            OperationKey.unwrap(Entity.operationKey(BlockNumber.wrap(1), 2, 3)),
            OperationKey.unwrap(Entity.operationKey(BlockNumber.wrap(1), 2, 3))
        );
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different keys
    // -------------------------------------------------------------------------

    function test_operationKey_differentBlock_differs() public pure {
        assertNotEq(
            OperationKey.unwrap(Entity.operationKey(BlockNumber.wrap(1), 1, 1)),
            OperationKey.unwrap(Entity.operationKey(BlockNumber.wrap(2), 1, 1))
        );
    }

    function test_operationKey_differentTx_differs() public pure {
        assertNotEq(
            OperationKey.unwrap(Entity.operationKey(BlockNumber.wrap(1), 1, 1)),
            OperationKey.unwrap(Entity.operationKey(BlockNumber.wrap(1), 2, 1))
        );
    }

    function test_operationKey_differentOp_differs() public pure {
        assertNotEq(
            OperationKey.unwrap(Entity.operationKey(BlockNumber.wrap(1), 1, 1)),
            OperationKey.unwrap(Entity.operationKey(BlockNumber.wrap(1), 1, 2))
        );
    }

    // -------------------------------------------------------------------------
    // Bit layout — manual verification
    // -------------------------------------------------------------------------

    function test_operationKey_layout() public pure {
        // GIVEN known inputs
        BlockNumber blockNumber = BlockNumber.wrap(0xAB);
        uint32 txSeq = 0xCD;
        uint32 opSeq = 0xEF;

        // WHEN packing
        uint256 packed = OperationKey.unwrap(Entity.operationKey(blockNumber, txSeq, opSeq));

        // THEN it matches the expected bit layout: block << 64 | tx << 32 | op
        uint256 expected = (0xAB << 64) | (uint256(0xCD) << 32) | 0xEF;
        assertEq(packed, expected);
    }

    function test_operationKey_zeroInputs() public pure {
        // GIVEN all zeros
        // THEN the packed key is zero
        assertEq(OperationKey.unwrap(Entity.operationKey(BlockNumber.wrap(0), 0, 0)), 0);
    }

    // -------------------------------------------------------------------------
    // Assembly correctness — fuzz
    // -------------------------------------------------------------------------

    function test_operationKey_fuzz(uint32 rawBlock, uint32 txSeq, uint32 opSeq) public pure {
        // GIVEN arbitrary inputs
        BlockNumber blockNumber = BlockNumber.wrap(rawBlock);

        // WHEN packing via the library
        uint256 actual = OperationKey.unwrap(Entity.operationKey(blockNumber, txSeq, opSeq));

        // THEN it matches the manual bit operation
        uint256 expected = (uint256(rawBlock) << 64) | (uint256(txSeq) << 32) | opSeq;
        assertEq(actual, expected);
    }

    // -------------------------------------------------------------------------
    // operationKey builds on transactionKey
    // -------------------------------------------------------------------------

    function test_operationKey_extendsTransactionKey(uint32 rawBlock, uint32 txSeq, uint32 opSeq) public pure {
        // GIVEN an operationKey and its corresponding transactionKey
        BlockNumber blockNumber = BlockNumber.wrap(rawBlock);
        uint256 ok = OperationKey.unwrap(Entity.operationKey(blockNumber, txSeq, opSeq));
        uint256 tk = TransactionKey.unwrap(Entity.transactionKey(blockNumber, txSeq));

        // THEN the upper bits of operationKey equal transactionKey shifted left by 32
        assertEq(ok >> 32, tk);
    }

    // =========================================================================
    // transactionKey
    // =========================================================================

    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_transactionKey_deterministic() public pure {
        // GIVEN the same inputs
        // WHEN packing twice
        // THEN the results are equal
        assertEq(
            TransactionKey.unwrap(Entity.transactionKey(BlockNumber.wrap(1), 2)),
            TransactionKey.unwrap(Entity.transactionKey(BlockNumber.wrap(1), 2))
        );
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different keys
    // -------------------------------------------------------------------------

    function test_transactionKey_differentBlock_differs() public pure {
        assertNotEq(
            TransactionKey.unwrap(Entity.transactionKey(BlockNumber.wrap(1), 1)),
            TransactionKey.unwrap(Entity.transactionKey(BlockNumber.wrap(2), 1))
        );
    }

    function test_transactionKey_differentTx_differs() public pure {
        assertNotEq(
            TransactionKey.unwrap(Entity.transactionKey(BlockNumber.wrap(1), 1)),
            TransactionKey.unwrap(Entity.transactionKey(BlockNumber.wrap(1), 2))
        );
    }

    // -------------------------------------------------------------------------
    // Bit layout — manual verification
    // -------------------------------------------------------------------------

    function test_transactionKey_layout() public pure {
        // GIVEN known inputs
        BlockNumber blockNumber = BlockNumber.wrap(0xAB);
        uint32 txSeq = 0xCD;

        // WHEN packing
        uint256 packed = TransactionKey.unwrap(Entity.transactionKey(blockNumber, txSeq));

        // THEN it matches the expected bit layout: block << 32 | tx
        uint256 expected = (0xAB << 32) | 0xCD;
        assertEq(packed, expected);
    }

    function test_transactionKey_zeroInputs() public pure {
        // GIVEN all zeros
        // THEN the packed key is zero
        assertEq(TransactionKey.unwrap(Entity.transactionKey(BlockNumber.wrap(0), 0)), 0);
    }

    // -------------------------------------------------------------------------
    // Assembly correctness — fuzz
    // -------------------------------------------------------------------------

    function test_transactionKey_fuzz(uint32 rawBlock, uint32 txSeq) public pure {
        // GIVEN arbitrary inputs
        BlockNumber blockNumber = BlockNumber.wrap(rawBlock);

        // WHEN packing via the library
        uint256 actual = TransactionKey.unwrap(Entity.transactionKey(blockNumber, txSeq));

        // THEN it matches the manual bit operation
        uint256 expected = (uint256(rawBlock) << 32) | txSeq;
        assertEq(actual, expected);
    }
}
