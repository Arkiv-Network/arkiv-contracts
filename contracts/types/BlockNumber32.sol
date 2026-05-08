// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Block number encoded as uint32.
///
/// uint32 overflows at block ~4.3 billion — ~272 years at 2s blocks,
/// ~136 years at 1s blocks (L2). Sufficient for any foreseeable chain.
///
/// The small width is intentional: three BlockNumber32s (12 bytes) pack
/// alongside an address (20 bytes) into a single 32-byte storage slot.
/// This enables the Commitment struct to fit in 3 slots and BlockNode
/// in 1 slot. A uint256 would double storage costs across the registry.
///
/// BlockNumber32s also pack into OperationKey and TransactionKey via bit
/// shifts, enabling O(1) composite key computation without hashing.
type BlockNumber32 is uint32;

using {
    blockNumberEq as ==,
    blockNumberNeq as !=,
    blockNumberLt as <,
    blockNumberLte as <=,
    blockNumberGt as >,
    blockNumberGte as >=,
    blockNumberAdd as +,
    blockNumberSub as -
} for BlockNumber32 global;

function blockNumberEq(BlockNumber32 a, BlockNumber32 b) pure returns (bool) {
    return BlockNumber32.unwrap(a) == BlockNumber32.unwrap(b);
}

function blockNumberNeq(BlockNumber32 a, BlockNumber32 b) pure returns (bool) {
    return BlockNumber32.unwrap(a) != BlockNumber32.unwrap(b);
}

function blockNumberLt(BlockNumber32 a, BlockNumber32 b) pure returns (bool) {
    return BlockNumber32.unwrap(a) < BlockNumber32.unwrap(b);
}

function blockNumberLte(BlockNumber32 a, BlockNumber32 b) pure returns (bool) {
    return BlockNumber32.unwrap(a) <= BlockNumber32.unwrap(b);
}

function blockNumberGt(BlockNumber32 a, BlockNumber32 b) pure returns (bool) {
    return BlockNumber32.unwrap(a) > BlockNumber32.unwrap(b);
}

function blockNumberGte(BlockNumber32 a, BlockNumber32 b) pure returns (bool) {
    return BlockNumber32.unwrap(a) >= BlockNumber32.unwrap(b);
}

function blockNumberAdd(BlockNumber32 a, BlockNumber32 b) pure returns (BlockNumber32) {
    return BlockNumber32.wrap(BlockNumber32.unwrap(a) + BlockNumber32.unwrap(b));
}

function blockNumberSub(BlockNumber32 a, BlockNumber32 b) pure returns (BlockNumber32) {
    return BlockNumber32.wrap(BlockNumber32.unwrap(a) - BlockNumber32.unwrap(b));
}

