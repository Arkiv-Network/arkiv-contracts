// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Block number encoded as uint32.
///
/// uint32 overflows at block ~4.3 billion — ~272 years at 2s blocks,
/// ~136 years at 1s blocks (L2). Sufficient for any foreseeable chain.
///
/// The small width is intentional: three BlockNumbers (12 bytes) pack
/// alongside an address (20 bytes) into a single 32-byte storage slot.
/// This enables the Commitment struct to fit in 3 slots and BlockNode
/// in 1 slot. A uint256 would double storage costs across the registry.
///
/// BlockNumbers also pack into OperationKey and TransactionKey via bit
/// shifts, enabling O(1) composite key computation without hashing.
type BlockNumber is uint32;

using {
    blockNumberEq as ==,
    blockNumberNeq as !=,
    blockNumberLt as <,
    blockNumberLte as <=,
    blockNumberGt as >,
    blockNumberGte as >=,
    blockNumberAdd as +,
    blockNumberSub as -
} for BlockNumber global;

function blockNumberEq(BlockNumber a, BlockNumber b) pure returns (bool) {
    return BlockNumber.unwrap(a) == BlockNumber.unwrap(b);
}

function blockNumberNeq(BlockNumber a, BlockNumber b) pure returns (bool) {
    return BlockNumber.unwrap(a) != BlockNumber.unwrap(b);
}

function blockNumberLt(BlockNumber a, BlockNumber b) pure returns (bool) {
    return BlockNumber.unwrap(a) < BlockNumber.unwrap(b);
}

function blockNumberLte(BlockNumber a, BlockNumber b) pure returns (bool) {
    return BlockNumber.unwrap(a) <= BlockNumber.unwrap(b);
}

function blockNumberGt(BlockNumber a, BlockNumber b) pure returns (bool) {
    return BlockNumber.unwrap(a) > BlockNumber.unwrap(b);
}

function blockNumberGte(BlockNumber a, BlockNumber b) pure returns (bool) {
    return BlockNumber.unwrap(a) >= BlockNumber.unwrap(b);
}

function blockNumberAdd(BlockNumber a, BlockNumber b) pure returns (BlockNumber) {
    return BlockNumber.wrap(BlockNumber.unwrap(a) + BlockNumber.unwrap(b));
}

function blockNumberSub(BlockNumber a, BlockNumber b) pure returns (BlockNumber) {
    return BlockNumber.wrap(BlockNumber.unwrap(a) - BlockNumber.unwrap(b));
}

