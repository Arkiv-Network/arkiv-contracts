// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber} from "./types/BlockNumber.sol";
import {Ident32} from "./types/Ident32.sol";
import {Entity} from "./Entity.sol";

/// @title IEntityRegistry
/// @notice External interface for the Arkiv EntityRegistry contract.
/// This interface is the single source of truth for Rust bindings generation
/// via alloy's sol! macro (compiled ABI is consumed by arkiv-bindings build.rs).
interface IEntityRegistry {
    // ── Events ──────────────────────────────────────────────────

    event EntityOperation(
        bytes32 indexed entityKey,
        uint8 indexed operationType,
        address indexed owner,
        BlockNumber expiresAt,
        bytes32 entityHash
    );

    // ── Errors ──────────────────────────────────────────────────

    error EmptyBatch();
    error AttributesNotSorted();
    error InvalidValueType(Ident32 name, uint8 valueType);
    error InvalidOpType(uint8 operationType);
    error ExpiryInPast(BlockNumber expiresAt, BlockNumber currentBlock);
    error TooManyAttributes(uint256 count, uint256 maxCount);
    error EntityNotFound(bytes32 entityKey);
    error NotOwner(bytes32 entityKey, address caller, address owner);
    error EntityExpired(bytes32 entityKey, BlockNumber expiresAt);
    error ExpiryNotExtended(bytes32 entityKey, BlockNumber newExpiresAt, BlockNumber currentExpiresAt);
    error TransferToZeroAddress(bytes32 entityKey);
    error TransferToSelf(bytes32 entityKey);
    error EntityNotExpired(bytes32 entityKey, BlockNumber expiresAt);

    // ── Write ───────────────────────────────────────────────────

    function execute(Entity.Operation[] calldata ops) external;

    // ── Read ────────────────────────────────────────────────────

    function changeSetHash() external view returns (bytes32);
    function changeSetHashAtBlock(BlockNumber blockNumber) external view returns (bytes32);
    function changeSetHashAtTx(BlockNumber blockNumber, uint32 txSeq) external view returns (bytes32);
    function changeSetHashAtOp(BlockNumber blockNumber, uint32 txSeq, uint32 opSeq) external view returns (bytes32);
    function commitment(bytes32 key) external view returns (Entity.Commitment memory);
    function entityKey(address owner, uint32 nonce) external view returns (bytes32);
    function genesisBlock() external view returns (BlockNumber);
    function headBlock() external view returns (BlockNumber);
    function getBlockNode(BlockNumber blockNumber) external view returns (Entity.BlockNode memory);
    function nonces(address owner) external view returns (uint32);
    function txOpCount(BlockNumber blockNumber, uint32 txSeq) external view returns (uint32);
}
