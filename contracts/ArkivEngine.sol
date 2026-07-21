// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber32} from "./types/BlockNumber32.sol";
import {EntityKey} from "./types/EntityKey.sol";
import {EntityV2} from "./EntityV2.sol";
import {Ident32} from "./types/Ident32.sol";
import {RecordReader} from "./RecordReader.sol";
import {RecordStore} from "./RecordStore.sol";

/// @title ArkivEngine
/// @dev The Arkiv engine — validation, dispatch, metering, and
/// record-store orchestration for the entity model
/// (docs/arkiv-engine.md). Production is implemented natively in the
/// Arkiv executor (no EVM), statically linked into the execution
/// client; inheritance mirrors that linkage here, and this contract
/// serves as the executable spec for differential testing against the
/// native implementation.
///
/// Abstract and stateless by design: no storage, no immutables — every
/// input arrives through the engine interface's (state, env, input) parameters,
/// so ambient-freedom is compiler-enforced. The execution client
/// (ExecutionClient) authenticates callers, binds the ExecutionEnv,
/// owns the protocol config and storage, and serves the query views; the engine is
/// the write path only.
///
/// Two stability contracts live at two layers: the ABI (execute, views,
/// events, errors) is per-data-model and must survive 1:1 across
/// implementations (this reference ↔ native); the interfaces (engine:
/// (state, env, input) → (outcome, cost); storage: records/cells) sit
/// below the model and must survive across data models — the entity
/// model is one plug-in, and a document/KV model would reuse the interfaces
/// with its own codecs, ABI, and events.
///
/// The state is a generic record/cell RecordStore (the §5 storage interface): an
/// entity is a record; the commitment data lives as system cells ($owner,
/// $creator, $expiresAt, …) beside $payload, $contentType, and the
/// custom attributes; per-owner nonces are ordinary records of their own.
/// All entity semantics — key derivation, name grammar, types, auth,
/// expiry — are engine-side; the store enforces only structure.
///
/// Known fidelity gaps vs the native executor:
///   - No reaping: expired entities stay in the store here, inert — every
///     op rejects them (EntityNotActive). The executor removes them
///     protocol-side with a per-block budget; a contract has no
///     block-boundary hook to emulate that, and reaping is an abstract
///     no-op on the active-entity state anyway.
///   - entityHash is emitted as bytes32(0) until the preimage is pinned.
///   - abi.decode accepts some non-canonical operationData encodings the
///     executor rejects.
abstract contract ArkivEngine {
    /// @dev Key tag and cell names for per-owner account records. An
    /// account carries two nonces: $txNonce advances by exactly 1 per
    /// successful tx (accounting + replay protection); $entityNonce is
    /// the key-derivation counter, advancing 0..n per tx (one per create).
    bytes32 internal constant ACCOUNT_RECORD_TAG = "arkiv/account";
    bytes32 internal constant TX_NONCE_CELL = "$txNonce";
    bytes32 internal constant ENTITY_NONCE_CELL = "$entityNonce";

    /// @dev The engine interface, ~1:1 with the native signature
    /// `execute<S: RecordStore>(state, env, input)`: decodes the raw input
    /// into the op list and applies it. The engine trusts env — this
    /// function must never be reachable except through the execution client's tx-context binding.
    ///
    /// Input and outcome are both opaque bytes so the signature
    /// survives a different data model on the same interfaces (documents, KV,
    /// …) — each model brings its own codec; the entity model decodes
    /// Operation[] and encodes EntityKey[] as its outcome.
    /// Result mapping: (outcome, cost) = ExecutionResult on success; a
    /// typed revert = outcome-level failure (cost is lost in the revert,
    /// unlike native); EngineFault is reserved for the native side. The
    /// meter enforces cost <= env.budget throughout.
    function execute(RecordStore state, EntityV2.ExecutionEnv memory env, bytes memory input)
        internal
        virtual
        returns (bytes memory outcome, uint64 cost)
    {
        // decode ops and high level validation
        EntityV2.Operation[] memory ops = abi.decode(input, (EntityV2.Operation[]));
        if (ops.length == 0) revert EntityV2.EmptyBatch();
        BlockNumber32 current = env.blockNumber;

        // set up cost meter and charge base fee
        EntityV2.Meter memory meter;
        EntityV2.charge(meter, env.budget, env.costs.executeBase);

        // accounting: every successful tx advances the caller's tx nonce
        // by exactly 1; the nonce-mismatch check itself is the execution
        // client's / tx envelope's job — the engine maintains the counter
        _touchAccount(state, env, meter);

        // dispatch each op in order, collecting the affected keys and charging the meter
        EntityKey[] memory keys = new EntityKey[](ops.length);
        for (uint256 i = 0; i < ops.length; i++) {
            keys[i] = _dispatch(state, ops[i], current, env, meter);
        }
        outcome = abi.encode(keys);
        cost = meter.cost;
    }

    // -------------------------------------------------------------------------
    // Internal functions — dispatch
    // -------------------------------------------------------------------------

    /// @dev Route an op to its handler: decode the payload selected by the
    /// operation tag, then apply. Unknown tags are a typed revert.
    /// @return The entity key affected by the op (minted key for CREATE).
    function _dispatch(
        RecordStore state,
        EntityV2.Operation memory op,
        BlockNumber32 current,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter
    ) internal virtual returns (EntityKey) {
        uint8 operation = op.operation;
        if (operation == EntityV2.CREATE) {
            return _create(state, EntityV2.decodeCreate(op.operationData), current, env, meter);
        }
        if (operation == EntityV2.PATCH) {
            return _patch(state, EntityV2.decodePatch(op.operationData), current, env, meter);
        }
        if (operation == EntityV2.EXTEND_EXPIRY) {
            return _extendExpiry(state, EntityV2.decodeExtendExpiry(op.operationData), current, env, meter);
        }
        if (operation == EntityV2.TRANSFER_OWNERSHIP) {
            return _transferOwnership(state, EntityV2.decodeTransferOwnership(op.operationData), current, env, meter);
        }
        if (operation == EntityV2.DELETE) {
            return _delete(state, EntityV2.decodeDelete(op.operationData), current, env, meter);
        }
        revert EntityV2.InvalidOperation(operation);
    }

    // -------------------------------------------------------------------------
    // Internal functions — entity operations
    // -------------------------------------------------------------------------

    /// @dev Mint a key from the caller's nonce, create the record, write the
    /// system cells and initial attributes. expiresAt = current + btl.
    function _create(
        RecordStore state,
        EntityV2.Create memory data,
        BlockNumber32 current,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter
    ) internal virtual returns (EntityKey key) {
        EntityV2.validateCreationFlags(data.creationFlags);
        EntityV2.validateAttributes(data.attributes, env.limits);
        BlockNumber32 expiresAt = EntityV2.expiryFromBtl(current, data.btl);

        // TODO more fine-grained cost accounting (business logic, not store):
        // - base charge per attribute (index manipulation)
        // - per byte and block to live (expiry) charge for payload attribute
        key = EntityV2.entityKey(env.constants.domain, env.caller, _consumeEntityNonce(state, env, meter));

        bytes32 record = EntityKey.unwrap(key);
        EntityV2.charge(meter, env.budget, env.costs.recordWrite);
        state.createRecord(record, EntityV2.RECORD_TYPE_ENTITY);

        _writeSystemCells(state, env, meter, record, current, expiresAt, data.creationFlags);
        (uint32 payloadSize, uint16 customAttributes) = _putAttributes(state, env, meter, record, data.attributes);

        emit EntityV2.EntityCreated(
            key, env.caller, expiresAt, bytes32(0), payloadSize, customAttributes, data.creationFlags
        );
    }

    /// @dev Apply a mutation list to an existing entity. Owner-only, active
    /// entities, blocked by readonly. Tombstoning an absent attribute is a
    /// no-op (idempotent patches).
    function _patch(
        RecordStore state,
        EntityV2.Patch memory data,
        BlockNumber32 current,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter
    ) internal virtual returns (EntityKey key) {
        key = data.entityKey;
        EntityV2.Commitment memory c = _loadCommitment(state, env, meter, key);

        EntityV2.requireExists(key, c);
        EntityV2.requireActive(key, c, current);
        EntityV2.requireOwner(key, c, env.caller);
        EntityV2.requireNotReadonly(key, c);
        EntityV2.validateMutations(data.mutations, env.limits);

        bytes32 record = EntityKey.unwrap(key);
        _applyMutations(state, env, meter, record, data.mutations);
        _putUintCell(state, env, meter, record, EntityV2.SYS_UPDATED_AT, BlockNumber32.unwrap(current));

        // derive the post-patch counters for the event, and enforce the
        // per-entity custom attribute cap — business logic, not a store rule
        uint32 payloadSize = _length32(_getCell(state, env, meter, record, EntityV2.SYS_PAYLOAD).value);
        uint16 customAttributes = _customCellCount(state, env, meter, record);
        if (customAttributes > env.limits.maxAttributes) {
            revert EntityV2.TooManyAttributes(customAttributes, env.limits.maxAttributes);
        }

        emit EntityV2.EntityPatched(key, c.owner, c.expiresAt, bytes32(0), payloadSize, customAttributes);
    }

    /// @dev Re-anchor expiry at the executing block: expiresAt = current +
    /// btl, strictly increasing. Owner-only unless permissionless extension.
    function _extendExpiry(
        RecordStore state,
        EntityV2.ExtendExpiry memory data,
        BlockNumber32 current,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter
    ) internal virtual returns (EntityKey key) {
        key = data.entityKey;
        EntityV2.Commitment memory c = _loadCommitment(state, env, meter, key);

        EntityV2.requireExists(key, c);
        EntityV2.requireActive(key, c, current);
        EntityV2.requireExtendAuth(key, c, env.caller);

        BlockNumber32 newExpiresAt = EntityV2.expiryFromBtl(current, data.btl);
        EntityV2.requireExpiryIncreased(key, newExpiresAt, c.expiresAt);

        bytes32 record = EntityKey.unwrap(key);
        _putUintCell(state, env, meter, record, EntityV2.SYS_EXPIRES_AT, BlockNumber32.unwrap(newExpiresAt));
        _putUintCell(state, env, meter, record, EntityV2.SYS_UPDATED_AT, BlockNumber32.unwrap(current));

        emit EntityV2.ExpiryExtended(key, c.owner, newExpiresAt, bytes32(0), c.expiresAt, env.caller);
    }

    /// @dev Transfer ownership. Owner-only, active entities, blocked by
    /// readonly; zero-address and self-transfer rejected.
    function _transferOwnership(
        RecordStore state,
        EntityV2.TransferOwnership memory data,
        BlockNumber32 current,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter
    ) internal virtual returns (EntityKey key) {
        key = data.entityKey;
        EntityV2.Commitment memory c = _loadCommitment(state, env, meter, key);

        EntityV2.requireExists(key, c);
        EntityV2.requireActive(key, c, current);
        EntityV2.requireOwner(key, c, env.caller);
        EntityV2.requireNotReadonly(key, c);
        EntityV2.requireNonZeroAddress(key, data.newOwner);
        EntityV2.requireNewOwner(key, data.newOwner, c.owner);

        bytes32 record = EntityKey.unwrap(key);
        _putAddressCell(state, env, meter, record, EntityV2.SYS_OWNER, data.newOwner);
        _putUintCell(state, env, meter, record, EntityV2.SYS_UPDATED_AT, BlockNumber32.unwrap(current));

        emit EntityV2.OwnershipTransferred(key, data.newOwner, c.expiresAt, bytes32(0), c.owner);
    }

    /// @dev Owner-initiated delete of an active entity. Expired entities
    /// are the protocol's business, not deletable via ops.
    function _delete(
        RecordStore state,
        EntityV2.Delete memory data,
        BlockNumber32 current,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter
    ) internal virtual returns (EntityKey key) {
        key = data.entityKey;
        EntityV2.Commitment memory c = _loadCommitment(state, env, meter, key);

        EntityV2.requireExists(key, c);
        EntityV2.requireActive(key, c, current);
        EntityV2.requireOwner(key, c, env.caller);
        EntityV2.requireNotReadonly(key, c);

        EntityV2.charge(meter, env.budget, env.costs.recordWrite);
        state.deleteRecord(EntityKey.unwrap(key));

        emit EntityV2.EntityDeleted(key, c.owner, c.expiresAt, bytes32(0));
    }

    // -------------------------------------------------------------------------
    // Internal functions — commitment as system cells
    // -------------------------------------------------------------------------

    /// @dev Assemble the guard-facing commitment view from the record's
    /// system cells. A nonexistent record yields an all-zero commitment
    /// (creator == 0), which requireExists rejects. The derived counters
    /// (payloadSize, customAttributes) are left zero — guards do not use
    /// them; events derive them separately.
    function _loadCommitment(
        RecordStore state,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter,
        EntityKey key
    ) internal virtual returns (EntityV2.Commitment memory c) {
        bytes32 record = EntityKey.unwrap(key);
        EntityV2.charge(meter, env.budget, env.costs.recordRead);
        if (!state.hasRecord(record)) return c;
        // Guard against type-confused keys before interpreting cells:
        // an existing record that is not an entity is a typed error, not
        // a garbled commitment.
        EntityV2.charge(meter, env.budget, env.costs.recordRead);
        uint8 recordType = state.recordType(record);
        if (recordType != EntityV2.RECORD_TYPE_ENTITY) {
            revert EntityV2.RecordTypeMismatch(record, EntityV2.RECORD_TYPE_ENTITY, recordType);
        }
        c.creator = _cellAddress(_getCell(state, env, meter, record, EntityV2.SYS_CREATOR));
        c.owner = _cellAddress(_getCell(state, env, meter, record, EntityV2.SYS_OWNER));
        c.createdAt = _cellBlockNumber(_getCell(state, env, meter, record, EntityV2.SYS_CREATED_AT));
        c.updatedAt = _cellBlockNumber(_getCell(state, env, meter, record, EntityV2.SYS_UPDATED_AT));
        c.expiresAt = _cellBlockNumber(_getCell(state, env, meter, record, EntityV2.SYS_EXPIRES_AT));
        // casting to 'uint8' is safe: written by the engine from a uint8
        // forge-lint: disable-next-line(unsafe-typecast)
        c.creationFlags = uint8(_cellUint(_getCell(state, env, meter, record, EntityV2.SYS_CREATION_FLAGS)));
    }

    /// @dev Write the commitment system cells of a fresh entity record.
    function _writeSystemCells(
        RecordStore state,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter,
        bytes32 record,
        BlockNumber32 current,
        BlockNumber32 expiresAt,
        uint8 creationFlags
    ) internal virtual {
        _putAddressCell(state, env, meter, record, EntityV2.SYS_CREATOR, env.caller);
        _putAddressCell(state, env, meter, record, EntityV2.SYS_OWNER, env.caller);
        _putUintCell(state, env, meter, record, EntityV2.SYS_CREATED_AT, BlockNumber32.unwrap(current));
        _putUintCell(state, env, meter, record, EntityV2.SYS_UPDATED_AT, BlockNumber32.unwrap(current));
        _putUintCell(state, env, meter, record, EntityV2.SYS_EXPIRES_AT, BlockNumber32.unwrap(expiresAt));
        _putUintCell(state, env, meter, record, EntityV2.SYS_CREATION_FLAGS, creationFlags);
    }

    /// @dev Write the create-time wire attributes as record cells and count
    /// the event-facing totals.
    function _putAttributes(
        RecordStore state,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter,
        bytes32 record,
        EntityV2.Attribute[] memory attributes
    ) internal virtual returns (uint32 payloadSize, uint16 customAttributes) {
        for (uint256 i = 0; i < attributes.length; i++) {
            EntityV2.Attribute memory a = attributes[i];
            _putCell(state, env, meter, record, RecordReader.Cell({name: a.name, typeId: a.typeId, value: a.value}));
            bytes32 raw = Ident32.unwrap(a.name);
            if (raw == EntityV2.SYS_PAYLOAD) payloadSize = _length32(a.value);
            else if (raw != EntityV2.SYS_CONTENT_TYPE) customAttributes++;
        }
    }

    /// @dev Apply patch mutations to the record: sets become cell puts,
    /// tombstones remove present cells and skip absent ones.
    function _applyMutations(
        RecordStore state,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter,
        bytes32 record,
        EntityV2.Attribute[] memory mutations
    ) internal virtual {
        for (uint256 i = 0; i < mutations.length; i++) {
            EntityV2.Attribute memory m = mutations[i];
            if (m.typeId == EntityV2.TYPE_TOMBSTONE) {
                RecordReader.Cell memory prev = _getCell(state, env, meter, record, Ident32.unwrap(m.name));
                if (Ident32.unwrap(prev.name) == 0) continue;
                EntityV2.charge(meter, env.budget, env.costs.recordWrite);
                state.removeCell(record, m.name);
            } else {
                _putCell(state, env, meter, record, RecordReader.Cell({name: m.name, typeId: m.typeId, value: m.value}));
            }
        }
    }

    // -------------------------------------------------------------------------
    // Internal functions — accounts as records
    // -------------------------------------------------------------------------

    /// @dev Ensure the caller's account record exists and advance its
    /// $txNonce by exactly 1 — called once per tx, so every successful
    /// tx increments it (a reverted tx rolls the increment back). The
    /// nonce-mismatch check against the tx envelope is the execution
    /// client's job; the engine only maintains the counter.
    function _touchAccount(RecordStore state, EntityV2.ExecutionEnv memory env, EntityV2.Meter memory meter)
        internal
        virtual
    {
        bytes32 account = _accountRecordKey(env.caller);
        RecordReader.Cell memory f = _getCell(state, env, meter, account, TX_NONCE_CELL);
        uint32 txNonce;
        if (Ident32.unwrap(f.name) == 0) {
            EntityV2.charge(meter, env.budget, env.costs.recordWrite);
            state.createRecord(account, EntityV2.RECORD_TYPE_ACCOUNT);
        } else {
            txNonce = _cellUint32(f);
        }
        _putUintCell(state, env, meter, account, TX_NONCE_CELL, uint256(txNonce) + 1);
    }

    /// @dev Per-owner entity-creation nonce — the key-derivation counter,
    /// advancing 0..n per tx (one per create). Returns the current value
    /// and post-increments. The account record is guaranteed to exist:
    /// _touchAccount ran earlier in the same tx for the same caller.
    function _consumeEntityNonce(RecordStore state, EntityV2.ExecutionEnv memory env, EntityV2.Meter memory meter)
        internal
        virtual
        returns (uint32 nonce)
    {
        bytes32 account = _accountRecordKey(env.caller);
        RecordReader.Cell memory f = _getCell(state, env, meter, account, ENTITY_NONCE_CELL);
        if (Ident32.unwrap(f.name) != 0) nonce = _cellUint32(f);
        _putUintCell(state, env, meter, account, ENTITY_NONCE_CELL, uint256(nonce) + 1);
    }

    function _accountRecordKey(address owner) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(ACCOUNT_RECORD_TAG, owner));
    }

    // -------------------------------------------------------------------------
    // Internal functions — custom cell counting
    // -------------------------------------------------------------------------

    /// @dev Number of custom cells of a record: the sorted enumeration
    /// minus its reserved/system prefix.
    function _customCellCount(
        RecordStore state,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter,
        bytes32 record
    ) internal virtual returns (uint16) {
        EntityV2.charge(meter, env.budget, env.costs.recordRead);
        Ident32[] memory names = state.cellNames(record);
        uint256 start;
        while (start < names.length && _isReservedOrSystem(names[start])) {
            start++;
        }
        // casting to 'uint16' is safe: bounded by the engine's custom cap
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(names.length - start);
    }

    /// @dev '#' is the store's key cell, '$' the engine's system
    /// namespace; everything else is a custom attribute (grammar
    /// guarantees a leading a-z).
    function _isReservedOrSystem(Ident32 name) internal pure returns (bool) {
        uint8 b = uint8(Ident32.unwrap(name)[0]);
        return b == 0x23 || b == 0x24;
    }

    // -------------------------------------------------------------------------
    // Internal functions — metered store access
    // -------------------------------------------------------------------------

    function _getCell(
        RecordStore state,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter,
        bytes32 record,
        bytes32 name
    ) internal virtual returns (RecordReader.Cell memory) {
        EntityV2.charge(meter, env.budget, env.costs.recordRead);
        return state.getCell(record, Ident32.wrap(name));
    }

    function _putCell(
        RecordStore state,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter,
        bytes32 record,
        RecordReader.Cell memory cell
    ) internal virtual {
        // casting to 'uint64' is safe: value lengths are bounded by maxPayloadBytes
        // forge-lint: disable-next-line(unsafe-typecast)
        EntityV2.charge(meter, env.budget, env.costs.recordWrite + uint64(cell.value.length) * env.costs.valueByte);
        state.putCell(record, cell);
    }

    function _putUintCell(
        RecordStore state,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter,
        bytes32 record,
        bytes32 name,
        uint256 value
    ) internal virtual {
        _putCell(
            state,
            env,
            meter,
            record,
            RecordReader.Cell({name: Ident32.wrap(name), typeId: EntityV2.TYPE_U256, value: abi.encode(value)})
        );
    }

    function _putAddressCell(
        RecordStore state,
        EntityV2.ExecutionEnv memory env,
        EntityV2.Meter memory meter,
        bytes32 record,
        bytes32 name,
        address value
    ) internal virtual {
        _putCell(
            state,
            env,
            meter,
            record,
            RecordReader.Cell({name: Ident32.wrap(name), typeId: EntityV2.TYPE_ADDRESS, value: abi.encode(value)})
        );
    }

    // -------------------------------------------------------------------------
    // Internal functions — cell decoding helpers
    // -------------------------------------------------------------------------

    function _cellAddress(RecordReader.Cell memory f) internal pure returns (address) {
        return abi.decode(f.value, (address));
    }

    function _cellUint(RecordReader.Cell memory f) internal pure returns (uint256) {
        return abi.decode(f.value, (uint256));
    }

    function _cellUint32(RecordReader.Cell memory f) internal pure returns (uint32) {
        // casting to 'uint32' is safe: written by the engine from a uint32
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(abi.decode(f.value, (uint256)));
    }

    function _cellBlockNumber(RecordReader.Cell memory f) internal pure returns (BlockNumber32) {
        return BlockNumber32.wrap(_cellUint32(f));
    }

    // -------------------------------------------------------------------------
    // Internal functions — misc helpers
    // -------------------------------------------------------------------------

    function _length32(bytes memory value) internal pure returns (uint32) {
        // casting to 'uint32' is safe: value sizes are far below 4 GiB
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(value.length);
    }
}
