// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ArkivEngine} from "./ArkivEngine.sol";
import {BlockNumber} from "./types/BlockNumber.sol";
import {EntityKey} from "./types/EntityKey.sol";
import {EntityV2} from "./EntityV2.sol";
import {Ident32} from "./types/Ident32.sol";
import {ProtocolParams} from "./ProtocolParams.sol";
import {RecordReader} from "./RecordReader.sol";
import {RecordStore} from "./RecordStore.sol";

/// @title ExecutionClient
/// @dev Reference stand-in for the adjusted reth execution
/// client: owns the protocol config and storage (ProtocolParams, RecordStore),
/// exposes the SDK-facing ABI (`execute` plus the query views),
/// authenticates callers, and binds the ExecutionEnv from tx context in
/// a dummy tx-context binding before invoking the engine interface. The
/// engine (ArkivEngine) is inherited — the contract analog of static
/// linkage into the client.
///
/// Reads live here deliberately: in the target architecture queries are
/// served by the client/DB layer, not the engine — the engine is the
/// write path only.
///
/// This ABI — execute, the views, the EntityV2 events and errors — is
/// the entity model's stability contract: it must survive 1:1 across
/// implementations (reference ↔ native). It is per-model by design;
/// the interfaces underneath are the layer that survives model swaps.
contract ExecutionClient is ArkivEngine {
    /// @dev Reverted when the block height exceeds the uint32
    /// BlockNumber range — the narrowing is the execution client's responsibility.
    error BlockNumberOutOfRange(uint256 blockNumber);

    // -------------------------------------------------------------------------
    // Protocol config and storage
    // -------------------------------------------------------------------------

    /// @dev §3 params registry: limits, costs, constants — probed once
    /// per batch.
    ProtocolParams public immutable PARAMS;

    /// @dev §5 storage interface: generic record/cell store. Deployed by the
    /// client, so the store's sole authorized writer is this contract.
    RecordStore public immutable STORE;

    constructor(ProtocolParams params) {
        PARAMS = params;
        STORE = new RecordStore();
    }

    // -------------------------------------------------------------------------
    // External functions
    // -------------------------------------------------------------------------

    /// @dev Arkiv executor RPC endpoint for tx sent by SDK.
    /// Execute an ordered, atomic batch of entity operations.
    /// Any op reverting rolls back the whole batch; op n+1 observes op n's
    /// effects; one event is emitted per applied op, in order.
    /// @return keys The entity key affected by each op, index-aligned with
    /// `ops` — for CREATE this is the minted key (obtainable without event
    /// parsing by simulating the call).
    function execute(EntityV2.Operation[] calldata ops) external returns (EntityKey[] memory keys) {
        // this call indicates the routing from the rpc endpoint to the tx-context binding
        // that part lives inside the adjusted reth
        return _executeFromTxContext(ops);
    }

    // -------------------------------------------------------------------------
    // Internal functions — tx-context binding
    // -------------------------------------------------------------------------

    /// @dev reth-side tx-context binding: builds the ExecutionEnv
    /// from the tx context, then invokes the engine interface.
    /// This is the only path into the engine interface — the env is trusted below this line.
    function _executeFromTxContext(EntityV2.Operation[] calldata ops)
        internal
        virtual
        returns (EntityKey[] memory keys)
    {
        // transform the calldata into the input data required by the engine interface
        bytes memory input = abi.encode(ops);

        // prepare the env for calling the engine
        EntityV2.ExecutionEnv memory env = EntityV2.ExecutionEnv({
            caller: msg.sender,
            // casting to 'uint64' is safe: gas limits are far below 2^64
            // forge-lint: disable-next-line(unsafe-typecast)
            budget: uint64(gasleft()),
            blockNumber: _blockNumber(),
            constants: PARAMS.constants(),
            limits: PARAMS.limits(),
            costs: PARAMS.costs()
        });

        // call the engine interface; decode the entity model's outcome codec
        (bytes memory outcome,) = execute(STORE, env, input);
        keys = abi.decode(outcome, (EntityKey[]));
    }

    /// @dev Host-side narrowing of block height to the engine's uint32
    /// BlockNumber time model. Fits for ~136 years at 1s blocks; the
    /// explicit check pins the boundary regardless.
    function _blockNumber() internal view returns (BlockNumber) {
        if (block.number > type(uint32).max) revert BlockNumberOutOfRange(block.number);
        // casting to 'uint32' is safe: bounds-checked directly above
        // forge-lint: disable-next-line(unsafe-typecast)
        return BlockNumber.wrap(uint32(block.number));
    }

    // -------------------------------------------------------------------------
    // Public view functions — the client/DB-layer query surface
    // -------------------------------------------------------------------------

    /// @dev Derive the entity key for an owner and nonce, bound to this
    /// deployment's domain — the same source the engine mints from.
    function entityKey(address owner, uint32 nonce) public view returns (EntityKey) {
        return EntityV2.entityKey(PARAMS.DOMAIN(), owner, nonce);
    }

    /// @dev The entity commitment, assembled from the record's system
    /// cells. Nonexistent entities — including keys of non-entity
    /// records — return an all-zero commitment.
    function commitment(EntityKey key) public view returns (EntityV2.Commitment memory c) {
        bytes32 record = EntityKey.unwrap(key);
        if (STORE.recordType(record) != EntityV2.RECORD_TYPE_ENTITY) return c;
        c.creator = _cellAddress(STORE.getCell(record, Ident32.wrap(EntityV2.SYS_CREATOR)));
        c.owner = _cellAddress(STORE.getCell(record, Ident32.wrap(EntityV2.SYS_OWNER)));
        c.createdAt = _cellBlockNumber(STORE.getCell(record, Ident32.wrap(EntityV2.SYS_CREATED_AT)));
        c.updatedAt = _cellBlockNumber(STORE.getCell(record, Ident32.wrap(EntityV2.SYS_UPDATED_AT)));
        c.expiresAt = _cellBlockNumber(STORE.getCell(record, Ident32.wrap(EntityV2.SYS_EXPIRES_AT)));
        // casting to 'uint8' is safe: written by the engine from a uint8
        // forge-lint: disable-next-line(unsafe-typecast)
        c.creationFlags = uint8(_cellUint(STORE.getCell(record, Ident32.wrap(EntityV2.SYS_CREATION_FLAGS))));
        c.payloadSize = _length32(STORE.getCell(record, Ident32.wrap(EntityV2.SYS_PAYLOAD)).value);
        // casting to 'uint16' is safe: bounded by the engine's custom cap
        // forge-lint: disable-next-line(unsafe-typecast)
        c.customAttributes = uint16(customAttributeNames(key).length);
    }

    function nonces(address owner) public view returns (uint32) {
        RecordReader.Cell memory f = STORE.getCell(_nonceRecordKey(owner), Ident32.wrap(NONCE_CELL));
        if (Ident32.unwrap(f.name) == 0) return 0;
        return _cellUint32(f);
    }

    /// @notice typeId of an attribute on an entity, 0 if absent.
    function attributeTypeId(EntityKey key, Ident32 name) public view returns (uint8) {
        return STORE.getCell(EntityKey.unwrap(key), name).typeId;
    }

    /// @dev The names of all set custom attributes of an entity, in
    /// strictly ascending order — the store's cell enumeration with the
    /// system ('$'-prefixed) cells skipped.
    function customAttributeNames(EntityKey key) public view returns (Ident32[] memory names) {
        Ident32[] memory all = STORE.cellNames(EntityKey.unwrap(key));
        // '#' (key cell) and '$' (system) sort before a-z, so the
        // non-custom cells form a prefix of the sorted list.
        uint256 start;
        while (start < all.length && _isReservedOrSystem(all[start])) {
            start++;
        }
        names = new Ident32[](all.length - start);
        for (uint256 i = start; i < all.length; i++) {
            names[i - start] = all[i];
        }
    }
}
