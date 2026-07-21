// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber32} from "./types/BlockNumber32.sol";
import {EntityKey} from "./types/EntityKey.sol";
import {IDENT_CHARSET, IDENT_LEADING, Ident32} from "./types/Ident32.sol";
import {
    MIME_TOKEN,
    S_TYPE,
    S_SUBTYPE,
    S_OWS,
    S_PNAME,
    S_PVALUE,
    MimeEmpty,
    MimeTooLong,
    MimeIncomplete,
    MimeInvalidByte
} from "./types/Mime128.sol";

/// @title EntityV2
/// @dev Pure types, validation, and guard logic for the V2 entity registry
/// op model (docs/arkiv-engine.md). The production registry is
/// implemented natively in the Arkiv executor (no EVM); ABI is retained
/// as the interface format, and this library pins that surface — types,
/// errors, events — while doubling as an executable reference for the
/// semantics.
///
/// An Operation is a tagged union: `operation` selects the payload
/// struct that `operationData` ABI-decodes to. New op types therefore
/// extend the protocol without changing the `execute()` signature.
/// Note: the native executor enforces canonical (strict) ABI encoding of
/// operationData; Solidity's abi.decode is laxer, so this reference
/// accepts some non-canonical encodings the executor rejects.
///
/// Intentionally absent (deferred by the v2 doc):
///   - $entityHash computation (preimage pinned with state epoch 1)
///   - changeset hash chain (OperationKey/BlockNode machinery of V1)
library EntityV2 {
    // -------------------------------------------------------------------------
    // Constants — operation types
    // -------------------------------------------------------------------------

    /// @dev Sentinel for uninitialized operation / typeId. Solidity
    /// zero-initializes uint8 fields, so unset discriminators carry this
    /// value. For typeId, 0 doubles as the tombstone discriminator.
    uint8 public constant UNINITIALIZED = 0;

    uint8 public constant CREATE = 1;
    uint8 public constant PATCH = 2;
    uint8 public constant EXTEND_EXPIRY = 3;
    uint8 public constant TRANSFER_OWNERSHIP = 4;
    uint8 public constant DELETE = 5;

    // -------------------------------------------------------------------------
    // Constants — value type ids (docs/arkiv-engine.md §1)
    // -------------------------------------------------------------------------

    /// @dev Tombstone: unsets an attribute. Valid only in mutations (patch);
    /// the only valid value is the empty byte string.
    uint8 public constant TYPE_TOMBSTONE = 0;
    uint8 public constant TYPE_BOOL = 1;
    /// @dev Signed 32-bit integer, ABI-encoded (sign-extended to 32 bytes).
    uint8 public constant TYPE_INT = 2;
    /// @dev Unsigned 256-bit integer, ABI-encoded (big-endian, 32 bytes).
    uint8 public constant TYPE_U256 = 3;
    /// @dev Fixed-point decimal: i256 with 18 implied decimals.
    uint8 public constant TYPE_DECIMAL = 4;
    uint8 public constant TYPE_BYTES32 = 5;
    /// @dev Unbounded byte string. System-only: valid solely for $payload.
    uint8 public constant TYPE_BYTES = 6;
    /// @dev UTF-8 string, at most 128 bytes. Character grammar TBD (§1).
    uint8 public constant TYPE_STRING = 7;
    uint8 public constant TYPE_ADDRESS = 8;
    uint8 public constant TYPE_ENTITY_KEY = 9;

    // -------------------------------------------------------------------------
    // Constants — record types
    // -------------------------------------------------------------------------

    // Arkiv's record type tags, carried in the store's key cell typeId
    // slot (0 = undefined, store default). The store treats them as
    // opaque; the engine assigns them at createRecord and asserts them
    // before interpreting a record — low-level protection against
    // type-confused keys.
    uint8 public constant RECORD_TYPE_ENTITY = 1;
    uint8 public constant RECORD_TYPE_ACCOUNT = 2;
    uint8 public constant RECORD_TYPE_INDEX = 3;

    // -------------------------------------------------------------------------
    // Constants — creation flags
    // -------------------------------------------------------------------------

    /// @dev Bit positions are proposed here; not yet ratified in the v2 doc.
    /// readonly: after create, only extend_expiry is permitted (no patch,
    /// no transfer, no delete); the protocol reclaims the entity at expiry.
    uint8 public constant FLAG_READONLY = 1 << 0;
    /// @dev permissionless_extension: removes the sender check for
    /// extend_expiry — and for no other op.
    uint8 public constant FLAG_PERMISSIONLESS_EXTENSION = 1 << 1;
    /// @dev Bits 2–7 are reserved for protocol upgrades and must be zero.
    uint8 internal constant FLAGS_MASK = FLAG_READONLY | FLAG_PERMISSIONLESS_EXTENSION;

    // -------------------------------------------------------------------------
    // Constants — system attribute names
    // -------------------------------------------------------------------------

    // System names are matched by exact bytes; any other '$'-prefixed name
    // is rejected as InvalidSystemAttribute, and the user-name grammar
    // (leading a-z) prevents shadowing from the user side.
    // '$' (0x24) sorts before a-z, so system attributes always come first
    // in the strictly-ascending attribute order.
    bytes32 internal constant SYS_PAYLOAD = "$payload";
    bytes32 internal constant SYS_CONTENT_TYPE = "$contentType";

    // Engine-managed system attributes: the commitment data stored as
    // record cells. NOT settable via the wire — the wire whitelist above stays
    // $payload / $contentType only; any other '$' name in an op reverts
    // InvalidSystemAttribute.
    bytes32 internal constant SYS_OWNER = "$owner";
    bytes32 internal constant SYS_CREATOR = "$creator";
    bytes32 internal constant SYS_CREATED_AT = "$createdAt";
    bytes32 internal constant SYS_UPDATED_AT = "$updatedAt";
    bytes32 internal constant SYS_EXPIRES_AT = "$expiresAt";
    bytes32 internal constant SYS_CREATION_FLAGS = "$creationFlags";

    // -------------------------------------------------------------------------
    // Constants — default limits
    // -------------------------------------------------------------------------

    /// @dev Default limit values. Active limits are consensus parameters
    /// probed from the ProtocolParams contract (§3 registry) — these
    /// defaults seed reference deployments. Final index caps TBD (§1).
    uint256 internal constant MAX_ATTRIBUTES = 32;
    uint256 internal constant MAX_MUTATIONS = 32;
    uint256 internal constant MAX_STRING_BYTES = 128;
    uint256 internal constant MAX_PAYLOAD_BYTES = 128 * 1024;

    /// @dev Consensus limits (validity rules) — the engine-facing view of
    /// the §3 params registry, mirroring the native `Limits` struct.
    /// Limits are height-selectable: they may change via protocol upgrade.
    struct Limits {
        uint256 maxAttributes;
        uint256 maxMutations;
        uint256 maxStringBytes;
        uint256 maxPayloadBytes;
    }

    /// @dev Chain-config constants — immutable for the chain's lifetime,
    /// unlike the height-selectable Limits. Part of the §3 params registry.
    struct Constants {
        /// Key-derivation domain separator: an abstract, globally unique
        /// value declared statically in chain config. Reference
        /// deployments conventionally use
        /// keccak256(abi.encodePacked(uint64 chainId, engine address));
        /// any unique value works. Changing it changes every derived key.
        bytes32 domain;
    }

    function defaultLimits() internal pure returns (Limits memory) {
        return Limits({
            maxAttributes: MAX_ATTRIBUTES,
            maxMutations: MAX_MUTATIONS,
            maxStringBytes: MAX_STRING_BYTES,
            maxPayloadBytes: MAX_PAYLOAD_BYTES
        });
    }

    // -------------------------------------------------------------------------
    // Constants — default costs
    // -------------------------------------------------------------------------

    /// @dev Default engine cost values, in engine cost units. Placeholder
    /// pricing pending §10 meter calibration; active values are probed
    /// from ProtocolParams.
    uint64 internal constant EXECUTE_BASE_COST = 1_000;
    uint64 internal constant RECORD_READ_COST = 100;
    uint64 internal constant RECORD_WRITE_COST = 500;
    uint64 internal constant VALUE_BYTE_COST = 2;

    /// @dev Engine cost constants — the §10 meter's price source,
    /// mirroring the native `write_costs`: per storage-op base costs plus
    /// per-byte factors. Height-selectable like Limits.
    struct Costs {
        /// Base cost for entering the engine.
        uint64 executeBase;
        /// Cost of a RecordStore read op.
        uint64 recordRead;
        /// Cost of a RecordStore write or delete op.
        uint64 recordWrite;
        /// Per-byte factor for attribute value bytes written.
        uint64 valueByte;
    }

    function defaultCosts() internal pure returns (Costs memory) {
        return Costs({
            executeBase: EXECUTE_BASE_COST,
            recordRead: RECORD_READ_COST,
            recordWrite: RECORD_WRITE_COST,
            valueByte: VALUE_BYTE_COST
        });
    }

    /// @dev Cost accumulator for one engine run. A memory struct so
    /// handlers can charge through a shared reference; the final value is
    /// the ExecutionResult.cost analog.
    struct Meter {
        uint64 cost;
    }

    /// @dev Charge `amount` against the meter, enforcing the invariant
    /// cost <= budget — the reference analog of the §10 meter.
    function charge(Meter memory meter, uint64 budget, uint64 amount) internal pure {
        uint64 newCost = meter.cost + amount;
        if (newCost > budget) revert BudgetExceeded(newCost, budget);
        meter.cost = newCost;
    }

    // -------------------------------------------------------------------------
    // Type declarations
    // -------------------------------------------------------------------------

    /// @dev Engine-facing execution environment, mirroring the native
    /// engine interface's ExecutionEnv. Every field is authenticated and bound
    /// by the execution client; the engine trusts it and reads no
    /// ambient context of its own. Chain config (Constants) rides with
    /// the params rather than as a separate env field.
    struct ExecutionEnv {
        /// Authenticated caller; the execution client binds msg.sender.
        address caller;
        /// Work allowance in engine cost units; the execution client binds tx gas limit −
        /// client intrinsic. Unused by the reference — the EVM meters gas.
        uint64 budget;
        /// Discrete monotone clock; the execution client binds and narrows block height —
        /// the engine's time model is uint32 end-to-end.
        BlockNumber32 blockNumber;
        /// Chain-config constants; the execution client probes ProtocolParams.
        Constants constants;
        /// Active §3 limits at this height; the execution client probes ProtocolParams.
        /// Temporary tuning affordance: model-specific config carried in
        /// the env only until values mature into engine constants
        /// (like EVM opcode costs).
        Limits limits;
        /// Active engine cost values at this height; the execution client probes
        /// ProtocolParams. Same temporary-tuning status as limits.
        Costs costs;
    }

    /// @dev Batch element: one entity operation within an `execute()` call.
    /// Tagged union: `operationData` is the ABI encoding of the payload
    /// struct selected by `operation`:
    ///   - CREATE:             Create
    ///   - PATCH:              Patch
    ///   - EXTEND_EXPIRY:      ExtendExpiry
    ///   - TRANSFER_OWNERSHIP: TransferOwnership
    ///   - DELETE:             Delete
    struct Operation {
        uint8 operation;
        bytes operationData;
    }

    /// @dev A (name, typeId, value) attribute write — the one wire shape
    /// shared by create and patch, lists strictly ascending by name.
    /// `value` holds the standard ABI encoding selected by `typeId`
    /// (32 bytes for word types, raw bytes for string/bytes). What an
    /// Attribute may express depends on context: at create it only sets;
    /// a patch-time mutation sets or removes by tombstone — the removal
    /// sentinel inside the data shape, as in JSON Merge Patch's null.
    struct Attribute {
        Ident32 name;
        uint8 typeId;
        bytes value;
    }

    /// @dev CREATE payload: mint a key, set initial attributes.
    /// Tombstones are disallowed — on a fresh entity, absence is expressed
    /// by omission. An empty list is valid (entity without content).
    struct Create {
        uint32 btl;
        uint8 creationFlags;
        Attribute[] attributes;
    }

    /// @dev PATCH payload: partial patch of an existing entity. Each
    /// mutation sets a user attribute or system key, or unsets one by
    /// tombstone. An empty list is a dead op and reverts.
    struct Patch {
        EntityKey entityKey;
        Attribute[] mutations;
    }

    /// @dev EXTEND_EXPIRY payload: re-anchor expiry at the executing block
    /// (new expiry = current + btl). Must strictly increase the expiry.
    struct ExtendExpiry {
        EntityKey entityKey;
        uint32 btl;
    }

    /// @dev TRANSFER_OWNERSHIP payload.
    struct TransferOwnership {
        EntityKey entityKey;
        address newOwner;
    }

    /// @dev DELETE payload. Owner-only, active entities only — expired
    /// entities are removed by the protocol, not by ops.
    struct Delete {
        EntityKey entityKey;
    }

    /// @dev Entity commitment — an in-memory/ABI view, not a storage
    /// struct: the engine assembles it from the record's system cells
    /// ($creator, $owner, $expiresAt, …). payloadSize and customAttributes
    /// are derived ($payload byte length, custom cell count). No hash
    /// field yet — the $entityHash preimage is deferred (§1).
    struct Commitment {
        address creator;
        BlockNumber32 createdAt;
        BlockNumber32 updatedAt;
        BlockNumber32 expiresAt;
        address owner;
        uint8 creationFlags;
        uint32 payloadSize;
        uint16 customAttributes;
    }

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    // One event per applied op, emitted in application order. Canonical
    // argument scheme shared by every event:
    //   topic1: entityKey
    //   topic2: owner — the owner valid AFTER the op
    //   topic3: expiresAt — the expiry valid AFTER the op
    //   data:   entityHash — the entity hash valid AFTER the op, followed
    //           by op-specific fields
    // entityHash is emitted as bytes32(0) until the $entityHash preimage
    // is pinned (§1) — the signature is stable, the value is not yet.
    // Deviation for EntityDeleted: the entity no longer exists after the
    // op, so owner, expiresAt, and entityHash carry the last values
    // before removal (zeros would carry no information).
    //
    // There is deliberately NO expiry/reap (GC) event. Reaping is
    // protocol-controlled and budgeted per block: the protocol cannot
    // guarantee removal at a specific block (it would otherwise fail
    // under an expiry-bomb attack — many entities expiring at the same
    // block). A reap event would therefore fire at reclaim time, not
    // expiry time, and any app that wants to show accurate information
    // must track the indexed expiresAt (EntityCreated / ExpiryExtended)
    // offchain anyway and apply the predicate: expired iff
    // expiresAt <= current block. Reaping itself is deterministic
    // consensus behavior — derivable by anyone, an abstract no-op on the
    // active-entity state, and unobservable in the event stream.

    /// @dev Entity minted. owner == creator == msg.sender.
    /// payloadSize: byte length of $payload (0 if unset).
    /// customAttributes: number of user attributes (system keys excluded).
    event EntityCreated(
        EntityKey indexed entityKey,
        address indexed owner,
        BlockNumber32 indexed expiresAt,
        bytes32 entityHash,
        uint32 payloadSize,
        uint16 customAttributes,
        uint8 creationFlags
    );

    /// @dev Entity content changed. owner == msg.sender (patch is owner-only).
    /// payloadSize / customAttributes reflect the state AFTER the patch.
    event EntityPatched(
        EntityKey indexed entityKey,
        address indexed owner,
        BlockNumber32 indexed expiresAt,
        bytes32 entityHash,
        uint32 payloadSize,
        uint16 customAttributes
    );

    /// @dev Expiry re-anchored (expiresAt = executing block + btl).
    /// caller == msg.sender: under permissionless extension it may be
    /// anyone, not the owner.
    event ExpiryExtended(
        EntityKey indexed entityKey,
        address indexed owner,
        BlockNumber32 indexed expiresAt,
        bytes32 entityHash,
        BlockNumber32 previousExpiresAt,
        address caller
    );

    /// @dev Ownership changed. owner is the NEW owner (post-op);
    /// previousOwner == msg.sender (transfer is owner-only).
    event OwnershipTransferred(
        EntityKey indexed entityKey,
        address indexed owner,
        BlockNumber32 indexed expiresAt,
        bytes32 entityHash,
        address previousOwner
    );

    /// @dev Owner-initiated delete of an active entity. owner == msg.sender.
    /// owner / expiresAt / entityHash snapshot the entity before removal.
    event EntityDeleted(
        EntityKey indexed entityKey, address indexed owner, BlockNumber32 indexed expiresAt, bytes32 entityHash
    );

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @dev Reverted when `execute()` is called with an empty ops array.
    error EmptyBatch();
    /// @dev Reverted when accumulated cost would exceed the env budget.
    error BudgetExceeded(uint64 cost, uint64 budget);
    /// @dev Reverted when a record's type tag does not match what the
    /// engine expects for the operation (e.g. a non-entity record key
    /// passed as an entityKey).
    error RecordTypeMismatch(bytes32 recordKey, uint8 expectedType, uint8 actualType);
    /// @dev Reverted when a patch carries no mutations (dead op). An empty
    /// attributes array at create is, by contrast, valid.
    error EmptyMutations();
    /// @dev Reverted when an operation tag is unrecognized (including 0 / uninitialized).
    error InvalidOperation(uint8 operation);
    /// @dev Reverted when a '$'-prefixed name is neither $payload nor $contentType.
    error InvalidSystemAttribute(Ident32 name);
    /// @dev Reverted when a name violates the user attribute grammar
    /// (leading a-z; then a-z, 0-9, '.', '-', '_'; no embedded nulls).
    error InvalidAttributeName(Ident32 name);
    /// @dev Reverted when the same name appears more than once in an
    /// attributes or mutations array.
    error NamesNotUnique(Ident32 name);
    /// @dev Reverted when attribute names are not in ascending order.
    error NamesNotSorted(Ident32 name);
    /// @dev Reverted when a typeId is unknown or not permitted for the name
    /// (e.g. TYPE_BYTES on a user attribute, non-BYTES on $payload).
    error InvalidValueType(Ident32 name, uint8 typeId);
    /// @dev Reverted when a value's byte length does not match the exact
    /// length its typeId requires (32 for word types, 0 for tombstones).
    error InvalidValueLength(Ident32 name, uint8 typeId, uint256 expectedLength, uint256 length);
    /// @dev Reverted when a variable-length value (string, bytes) exceeds
    /// its maximum allowed length.
    error MaxValueLengthExceeded(Ident32 name, uint8 typeId, uint256 maxLength, uint256 length);
    /// @dev Reverted when a 32-byte value is not canonical for its typeId
    /// (bool not 0/1, int outside int32, address with nonzero padding).
    error InvalidValueEncoding(Ident32 name, uint8 typeId);
    /// @dev Reverted on a tombstone outside patch (dead instruction).
    error TombstoneNotAllowed(Ident32 name);
    /// @dev Reverted when a reserved creation flag bit is set.
    error InvalidCreationFlags(uint8 creationFlags);
    /// @dev Reverted when the attribute count exceeds MAX_ATTRIBUTES.
    error TooManyAttributes(uint256 count, uint256 maxCount);
    /// @dev Reverted when the mutation count exceeds MAX_MUTATIONS.
    error TooManyMutations(uint256 count, uint256 maxCount);
    /// @dev Reverted when btl is zero.
    error ZeroBtl();
    /// @dev Reverted when current + btl exceeds the uint32 block range.
    error ExpiryOverflow(BlockNumber32 current, uint32 btl);
    /// @dev Reverted when extend_expiry would not strictly increase expiry.
    error ExpiryNotExtended(EntityKey entityKey, BlockNumber32 newExpiresAt, BlockNumber32 currentExpiresAt);
    /// @dev Reverted when an entity key does not exist in storage.
    error EntityNotFound(EntityKey entityKey);
    /// @dev Reverted when an operation targets an expired entity.
    /// (Named to leave `EntityExpired` to the removal event.)
    error EntityNotActive(EntityKey entityKey, BlockNumber32 expiresAt);
    /// @dev Reverted when the caller is not authorized for the operation.
    error NotOwner(EntityKey entityKey, address caller, address owner);
    /// @dev Reverted when patch/transfer/delete targets a readonly entity.
    error EntityReadonly(EntityKey entityKey);
    /// @dev Reverted when transfer target is the zero address.
    error TransferToZeroAddress(EntityKey entityKey);
    /// @dev Reverted when transfer target is the current owner (no-op).
    error TransferToSelf(EntityKey entityKey);

    // -------------------------------------------------------------------------
    // Payload decoding
    // -------------------------------------------------------------------------

    function decodeCreate(bytes memory operationData) internal pure returns (Create memory) {
        return abi.decode(operationData, (Create));
    }

    function decodePatch(bytes memory operationData) internal pure returns (Patch memory) {
        return abi.decode(operationData, (Patch));
    }

    function decodeExtendExpiry(bytes memory operationData) internal pure returns (ExtendExpiry memory) {
        return abi.decode(operationData, (ExtendExpiry));
    }

    function decodeTransferOwnership(bytes memory operationData) internal pure returns (TransferOwnership memory) {
        return abi.decode(operationData, (TransferOwnership));
    }

    function decodeDelete(bytes memory operationData) internal pure returns (Delete memory) {
        return abi.decode(operationData, (Delete));
    }

    // -------------------------------------------------------------------------
    // Guards
    // -------------------------------------------------------------------------

    // Guards take Commitment memory: the engine loads a record from the
    // store, checks and transforms it in memory, and writes it back —
    // mirroring the native read-transform-write flow over the §5 storage interface.

    /// @dev Require that the entity exists (creator != address(0)).
    function requireExists(EntityKey key, Commitment memory c) internal pure {
        if (c.creator == address(0)) revert EntityNotFound(key);
    }

    /// @dev Require that the entity has not expired (expiresAt > current).
    /// Expiry is a predicate: expired entities reject every op; their
    /// removal is protocol-controlled.
    function requireActive(EntityKey key, Commitment memory c, BlockNumber32 current) internal pure {
        if (c.expiresAt <= current) revert EntityNotActive(key, c.expiresAt);
    }

    /// @dev Require that the caller is the entity owner. The caller comes
    /// from ExecutionEnv — authenticated by the execution client, trusted by the engine.
    function requireOwner(EntityKey key, Commitment memory c, address caller) internal pure {
        if (caller != c.owner) revert NotOwner(key, caller, c.owner);
    }

    /// @dev Require that the entity is not readonly. Applies to patch,
    /// transfer_ownership, and owner-delete; never to extend_expiry.
    function requireNotReadonly(EntityKey key, Commitment memory c) internal pure {
        if (c.creationFlags & FLAG_READONLY != 0) revert EntityReadonly(key);
    }

    /// @dev Authorization for extend_expiry: owner-only unless the entity
    /// was created with permissionless extension.
    function requireExtendAuth(EntityKey key, Commitment memory c, address caller) internal pure {
        if (c.creationFlags & FLAG_PERMISSIONLESS_EXTENSION != 0) return;
        if (caller != c.owner) revert NotOwner(key, caller, c.owner);
    }

    /// @dev Require that the address is not zero.
    function requireNonZeroAddress(EntityKey key, address addr) internal pure {
        if (addr == address(0)) revert TransferToZeroAddress(key);
    }

    /// @dev Require that the new owner is different from the current owner.
    function requireNewOwner(EntityKey key, address newOwner, address currentOwner) internal pure {
        if (newOwner == currentOwner) revert TransferToSelf(key);
    }

    /// @dev Require that the new expiry is strictly greater than the current
    /// one. extend_expiry anchors at the executing block (new expiry =
    /// current + btl) and must never shorten the entity's lifetime.
    function requireExpiryIncreased(EntityKey key, BlockNumber32 newExpiresAt, BlockNumber32 currentExpiresAt)
        internal
        pure
    {
        if (newExpiresAt <= currentExpiresAt) revert ExpiryNotExtended(key, newExpiresAt, currentExpiresAt);
    }

    // -------------------------------------------------------------------------
    // Validation — btl and creation flags
    // -------------------------------------------------------------------------

    /// @notice Compute an expiry block from the executing block and a btl
    /// (blocks-to-live). btl must be strictly positive; the result must fit
    /// the uint32 block range.
    function expiryFromBtl(BlockNumber32 current, uint32 btl) internal pure returns (BlockNumber32) {
        if (btl == 0) revert ZeroBtl();
        uint256 expiresAt = uint256(BlockNumber32.unwrap(current)) + btl;
        if (expiresAt > type(uint32).max) revert ExpiryOverflow(current, btl);
        // casting to 'uint32' is safe: bounds-checked directly above
        // forge-lint: disable-next-line(unsafe-typecast)
        return BlockNumber32.wrap(uint32(expiresAt));
    }

    /// @notice Validate creation flags: reserved bits (2–7) must be zero.
    function validateCreationFlags(uint8 creationFlags) internal pure {
        if (creationFlags & ~FLAGS_MASK != 0) revert InvalidCreationFlags(creationFlags);
    }

    // -------------------------------------------------------------------------
    // Validation — attribute and mutation lists
    // -------------------------------------------------------------------------

    /// @notice Validate a create-time attribute list: strictly ascending
    /// names, no tombstones, per-type value encoding. An empty list is
    /// valid — an entity may be created without content.
    function validateAttributes(Attribute[] memory attributes, Limits memory limits) internal pure {
        if (attributes.length > limits.maxAttributes) {
            revert TooManyAttributes(attributes.length, limits.maxAttributes);
        }
        Ident32 prevName;
        for (uint256 i = 0; i < attributes.length; i++) {
            prevName = validateAttribute(prevName, attributes[i], false, limits);
        }
    }

    /// @notice Validate a patch-time mutation list: strictly ascending
    /// names, tombstones allowed, per-type value encoding. An empty list
    /// is a dead op and reverts.
    function validateMutations(Attribute[] memory mutations, Limits memory limits) internal pure {
        if (mutations.length == 0) revert EmptyMutations();
        if (mutations.length > limits.maxMutations) {
            revert TooManyMutations(mutations.length, limits.maxMutations);
        }
        Ident32 prevName;
        for (uint256 i = 0; i < mutations.length; i++) {
            prevName = validateAttribute(prevName, mutations[i], true, limits);
        }
    }

    /// @dev Validate a single attribute write: name grammar first (system
    /// names by exact match, user names against the identifier grammar),
    /// then ordering/uniqueness against the previous name, then the
    /// typeId/value rules for the name's class.
    /// @return The validated name, to be threaded as the next prevName.
    function validateAttribute(
        Ident32 prevName,
        Attribute memory attribute,
        bool tombstoneAllowed,
        Limits memory limits
    ) internal pure returns (Ident32) {
        Ident32 name = attribute.name;
        uint8 typeId = attribute.typeId;
        bytes32 raw = Ident32.unwrap(name);

        if (uint8(raw[0]) == 0x24) {
            // '$' prefix: must be a known system attribute.
            if (raw != SYS_PAYLOAD && raw != SYS_CONTENT_TYPE) revert InvalidSystemAttribute(name);
        } else if (!isValidUserName(raw)) {
            revert InvalidAttributeName(name);
        }

        if (name == prevName) revert NamesNotUnique(name);
        if (name < prevName) revert NamesNotSorted(name);

        if (typeId == TYPE_TOMBSTONE) {
            // Tombstones may target system keys as well as user attributes.
            if (!tombstoneAllowed) revert TombstoneNotAllowed(name);
            if (attribute.value.length != 0) revert InvalidValueLength(name, typeId, 0, attribute.value.length);
        } else if (raw == SYS_PAYLOAD) {
            if (typeId != TYPE_BYTES) revert InvalidValueType(name, typeId);
            if (attribute.value.length > limits.maxPayloadBytes) {
                revert MaxValueLengthExceeded(name, typeId, limits.maxPayloadBytes, attribute.value.length);
            }
        } else if (raw == SYS_CONTENT_TYPE) {
            if (typeId != TYPE_STRING) revert InvalidValueType(name, typeId);
            validateMimeValue(attribute.value, limits.maxStringBytes);
        } else {
            validateUserValue(name, typeId, attribute.value, limits.maxStringBytes);
        }
        return name;
    }

    /// @dev Check a name against the user attribute grammar (Ident32:
    /// leading a-z; then a-z, 0-9, '.', '-', '_'; left-aligned, no
    /// embedded nulls). Boolean variant so the caller can revert with
    /// InvalidAttributeName instead of the Ident32 library errors.
    function isValidUserName(bytes32 raw) internal pure returns (bool) {
        uint8 b0 = uint8(raw[0]);
        if ((IDENT_LEADING >> b0) & 1 == 0) return false;
        bool zeroSeen;
        for (uint256 i = 1; i < 32; i++) {
            uint8 b = uint8(raw[i]);
            if (b == 0) {
                zeroSeen = true;
            } else if (zeroSeen || (IDENT_CHARSET >> b) & 1 == 0) {
                return false;
            }
        }
        return true;
    }

    /// @dev Validate a user attribute value against its typeId. Word types
    /// must be exactly 32 bytes and canonically encoded — one valid byte
    /// representation per logical value, so no hash malleability.
    function validateUserValue(Ident32 name, uint8 typeId, bytes memory value, uint256 maxStringBytes) internal pure {
        if (typeId == TYPE_STRING) {
            if (value.length > maxStringBytes) {
                revert MaxValueLengthExceeded(name, typeId, maxStringBytes, value.length);
            }
            return;
        }
        // TYPE_BYTES is system-only ($payload); unknown ids end here too.
        if (typeId == TYPE_BYTES || typeId > TYPE_ENTITY_KEY) revert InvalidValueType(name, typeId);

        if (value.length != 32) revert InvalidValueLength(name, typeId, 32, value.length);
        // casting to 'bytes32' is safe: length is checked to be exactly 32
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 word = uint256(bytes32(value));
        if (typeId == TYPE_BOOL) {
            if (word > 1) revert InvalidValueEncoding(name, typeId);
        } else if (typeId == TYPE_INT) {
            // casting to 'int256' is safe: same-width sign reinterpretation
            // forge-lint: disable-next-line(unsafe-typecast)
            int256 v = int256(word);
            if (v < type(int32).min || v > type(int32).max) revert InvalidValueEncoding(name, typeId);
        } else if (typeId == TYPE_ADDRESS) {
            if (word >> 160 != 0) revert InvalidValueEncoding(name, typeId);
        }
        // TYPE_U256, TYPE_DECIMAL, TYPE_BYTES32, TYPE_ENTITY_KEY: any word.
    }

    /// @dev Validate a $contentType value as a MIME type per RFC 2045.
    /// Mirrors validateMime128's state machine for length-delimited bytes
    /// (the V1 validator walks a zero-terminated fixed container). Embedded
    /// zero bytes fail the token bitmap and revert.
    function validateMimeValue(bytes memory value, uint256 maxStringBytes) internal pure returns (uint256) {
        uint256 length = value.length;
        if (length == 0) revert MimeEmpty();
        if (length > maxStringBytes) revert MimeTooLong(length, maxStringBytes);

        uint8 state = S_TYPE;
        uint256 segLen;
        for (uint256 i = 0; i < length; i++) {
            uint8 b = uint8(value[i]);
            if (state == S_TYPE) {
                if ((MIME_TOKEN >> b) & 1 == 1) segLen++;
                else if (b == 0x2F && segLen > 0) (state, segLen) = (S_SUBTYPE, 0);
                else revert MimeInvalidByte(i, bytes1(b));
            } else if (state == S_SUBTYPE) {
                if ((MIME_TOKEN >> b) & 1 == 1) segLen++;
                else if (b == 0x3B && segLen > 0) (state, segLen) = (S_OWS, 0);
                else revert MimeInvalidByte(i, bytes1(b));
            } else if (state == S_OWS) {
                if (b == 0x20) continue;
                else if ((MIME_TOKEN >> b) & 1 == 1) (state, segLen) = (S_PNAME, 1);
                else revert MimeInvalidByte(i, bytes1(b));
            } else if (state == S_PNAME) {
                if ((MIME_TOKEN >> b) & 1 == 1) segLen++;
                else if (b == 0x3D && segLen > 0) (state, segLen) = (S_PVALUE, 0);
                else revert MimeInvalidByte(i, bytes1(b));
            } else {
                if ((MIME_TOKEN >> b) & 1 == 1) segLen++;
                else if (b == 0x3B && segLen > 0) (state, segLen) = (S_OWS, 0);
                else revert MimeInvalidByte(i, bytes1(b));
            }
        }
        if ((state == S_SUBTYPE || state == S_PVALUE) && segLen > 0) return length;
        revert MimeIncomplete();
    }

    // -------------------------------------------------------------------------
    // Key derivation
    // -------------------------------------------------------------------------

    /// @notice Derive a globally unique entity key from the domain
    /// separator, owner, and nonce. Deterministic: clients precompute
    /// keys for same-batch composition (create, then patch the predicted
    /// key). Preimage: domain (32) ‖ owner (20) ‖ nonce (4) = 56 bytes.
    function entityKey(bytes32 domain, address owner, uint32 nonce) internal pure returns (EntityKey) {
        return EntityKey.wrap(keccak256(abi.encodePacked(domain, owner, nonce)));
    }
}
