// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber} from "../../src/types/BlockNumber.sol";
import {EntityKey} from "../../src/types/EntityKey.sol";
import {ExecutionClient} from "../../src/ExecutionClient.sol";
import {EntityV2} from "../../src/EntityV2.sol";
import {Ident32, encodeIdent32} from "../../src/types/Ident32.sol";
import {ProtocolParams} from "../../src/ProtocolParams.sol";
import {RecordReader} from "../../src/RecordReader.sol";
import {RecordStore} from "../../src/RecordStore.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Full-lifecycle tests for the V2 reference client: batch execute,
/// tagged-union dispatch, attribute/mutation bookkeeping, flags, expiry
/// predicate, and the canonical event schema.
contract ExecutionClientTest is Test {
    ExecutionClient client;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    Ident32 PAYLOAD = Ident32.wrap("$payload");
    Ident32 CONTENT_TYPE = Ident32.wrap("$contentType");
    Ident32 COLOR = encodeIdent32("color");
    Ident32 SIZE = encodeIdent32("size");

    function setUp() public {
        client =
            new ExecutionClient(new ProtocolParams(EntityV2.defaultLimits(), EntityV2.defaultCosts(), testConstants()));
        vm.roll(100);
    }

    function testConstants() internal pure returns (EntityV2.Constants memory) {
        return EntityV2.Constants({domain: keccak256("arkiv/test-domain")});
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function attr(Ident32 name, uint8 typeId, bytes memory value) internal pure returns (EntityV2.Attribute memory) {
        return EntityV2.Attribute({name: name, typeId: typeId, value: value});
    }

    function op(uint8 operation, bytes memory operationData) internal pure returns (EntityV2.Operation memory) {
        return EntityV2.Operation({operation: operation, operationData: operationData});
    }

    function createOp(uint32 btl, uint8 flags, EntityV2.Attribute[] memory attrs)
        internal
        pure
        returns (EntityV2.Operation memory)
    {
        return op(EntityV2.CREATE, abi.encode(EntityV2.Create({btl: btl, creationFlags: flags, attributes: attrs})));
    }

    function patchOp(EntityKey key, EntityV2.Attribute[] memory mutations)
        internal
        pure
        returns (EntityV2.Operation memory)
    {
        return op(EntityV2.PATCH, abi.encode(EntityV2.Patch({entityKey: key, mutations: mutations})));
    }

    function extendOp(EntityKey key, uint32 btl) internal pure returns (EntityV2.Operation memory) {
        return op(EntityV2.EXTEND_EXPIRY, abi.encode(EntityV2.ExtendExpiry({entityKey: key, btl: btl})));
    }

    function transferOp(EntityKey key, address newOwner) internal pure returns (EntityV2.Operation memory) {
        return
            op(
                EntityV2.TRANSFER_OWNERSHIP,
                abi.encode(EntityV2.TransferOwnership({entityKey: key, newOwner: newOwner}))
            );
    }

    function deleteOp(EntityKey key) internal pure returns (EntityV2.Operation memory) {
        return op(EntityV2.DELETE, abi.encode(EntityV2.Delete({entityKey: key})));
    }

    function executeOne(EntityV2.Operation memory operation) internal returns (EntityKey) {
        EntityV2.Operation[] memory ops = new EntityV2.Operation[](1);
        ops[0] = operation;
        EntityKey[] memory keys = client.execute(ops);
        // Under vm.expectRevert the consumed call returns empty returndata,
        // decoding to an empty array — guard the index.
        return keys.length > 0 ? keys[0] : EntityKey.wrap(0);
    }

    function threeAttrs() internal view returns (EntityV2.Attribute[] memory attrs) {
        // Sorted: "$contentType" < "$payload" < "color".
        attrs = new EntityV2.Attribute[](3);
        attrs[0] = attr(CONTENT_TYPE, EntityV2.TYPE_STRING, "text/plain");
        attrs[1] = attr(PAYLOAD, EntityV2.TYPE_BYTES, "hello");
        attrs[2] = attr(COLOR, EntityV2.TYPE_STRING, "red");
    }

    /// @dev Create a default entity as alice: btl 50, no flags, 3 attributes.
    function createDefault() internal returns (EntityKey key) {
        key = client.entityKey(alice, client.nonces(alice));
        vm.prank(alice);
        executeOne(createOp(50, 0, threeAttrs()));
    }

    // -------------------------------------------------------------------------
    // create
    // -------------------------------------------------------------------------

    function test_create_storesCommitmentAndEmits() public {
        EntityKey key = client.entityKey(alice, 0);

        vm.expectEmit();
        emit EntityV2.EntityCreated(key, alice, BlockNumber.wrap(150), bytes32(0), 5, 1, 0);
        vm.prank(alice);
        EntityKey returned = executeOne(createOp(50, 0, threeAttrs()));
        assertEq(EntityKey.unwrap(returned), EntityKey.unwrap(key));

        EntityV2.Commitment memory c = client.commitment(key);
        assertEq(c.creator, alice);
        assertEq(c.owner, alice);
        assertEq(BlockNumber.unwrap(c.createdAt), 100);
        assertEq(BlockNumber.unwrap(c.expiresAt), 150);
        assertEq(c.payloadSize, 5);
        assertEq(c.customAttributes, 1);
        assertEq(client.nonces(alice), 1);
        assertEq(client.attributeTypeId(key, COLOR), EntityV2.TYPE_STRING);
        assertEq(client.attributeTypeId(key, PAYLOAD), EntityV2.TYPE_BYTES);
        assertEq(client.attributeTypeId(key, SIZE), 0);
    }

    function test_create_emptyAttributes_isValid() public {
        EntityKey key = client.entityKey(alice, 0);
        vm.prank(alice);
        executeOne(createOp(10, 0, new EntityV2.Attribute[](0)));
        assertEq(client.commitment(key).creator, alice);
        assertEq(client.commitment(key).customAttributes, 0);
    }

    function test_create_zeroBtl_reverts() public {
        vm.expectRevert(EntityV2.ZeroBtl.selector);
        vm.prank(alice);
        executeOne(createOp(0, 0, new EntityV2.Attribute[](0)));
    }

    function test_create_tombstone_reverts() public {
        EntityV2.Attribute[] memory attrs = new EntityV2.Attribute[](1);
        attrs[0] = attr(COLOR, EntityV2.TYPE_TOMBSTONE, "");
        vm.expectRevert(abi.encodeWithSelector(EntityV2.TombstoneNotAllowed.selector, COLOR));
        vm.prank(alice);
        executeOne(createOp(10, 0, attrs));
    }

    function test_create_reservedFlags_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(EntityV2.InvalidCreationFlags.selector, uint8(0x04)));
        vm.prank(alice);
        executeOne(createOp(10, 0x04, new EntityV2.Attribute[](0)));
    }

    function test_create_unknownSystemAttribute_reverts() public {
        EntityV2.Attribute[] memory attrs = new EntityV2.Attribute[](1);
        attrs[0] = attr(Ident32.wrap("$bogus"), EntityV2.TYPE_STRING, "x");
        vm.expectRevert(abi.encodeWithSelector(EntityV2.InvalidSystemAttribute.selector, Ident32.wrap("$bogus")));
        vm.prank(alice);
        executeOne(createOp(10, 0, attrs));
    }

    // -------------------------------------------------------------------------
    // patch
    // -------------------------------------------------------------------------

    function test_patch_setRemoveResize() public {
        EntityKey key = createDefault();

        // Sorted: "$payload" < "color" < "size".
        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](3);
        mutations[0] = attr(PAYLOAD, EntityV2.TYPE_BYTES, "hello, world"); // resize 5 → 12
        mutations[1] = attr(COLOR, EntityV2.TYPE_TOMBSTONE, ""); // remove   1 → 0
        mutations[2] = attr(SIZE, EntityV2.TYPE_U256, abi.encode(uint256(42))); // add 0 → 1

        vm.expectEmit();
        emit EntityV2.EntityPatched(key, alice, BlockNumber.wrap(150), bytes32(0), 12, 1);
        vm.prank(alice);
        executeOne(patchOp(key, mutations));

        EntityV2.Commitment memory c = client.commitment(key);
        assertEq(c.payloadSize, 12);
        assertEq(c.customAttributes, 1);
        assertEq(client.attributeTypeId(key, COLOR), 0);
        assertEq(client.attributeTypeId(key, SIZE), EntityV2.TYPE_U256);
    }

    function test_patch_overwrite_keepsCount() public {
        EntityKey key = createDefault();
        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](1);
        mutations[0] = attr(COLOR, EntityV2.TYPE_STRING, "blue");
        vm.prank(alice);
        executeOne(patchOp(key, mutations));
        assertEq(client.commitment(key).customAttributes, 1);
    }

    function test_patch_tombstoneAbsent_isNoop() public {
        EntityKey key = createDefault();
        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](1);
        mutations[0] = attr(SIZE, EntityV2.TYPE_TOMBSTONE, "");
        vm.prank(alice);
        executeOne(patchOp(key, mutations));
        assertEq(client.commitment(key).customAttributes, 1);
    }

    function test_patch_notOwner_reverts() public {
        EntityKey key = createDefault();
        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](1);
        mutations[0] = attr(COLOR, EntityV2.TYPE_STRING, "blue");
        vm.expectRevert(abi.encodeWithSelector(EntityV2.NotOwner.selector, key, bob, alice));
        vm.prank(bob);
        executeOne(patchOp(key, mutations));
    }

    function test_patch_emptyMutations_reverts() public {
        EntityKey key = createDefault();
        vm.expectRevert(EntityV2.EmptyMutations.selector);
        vm.prank(alice);
        executeOne(patchOp(key, new EntityV2.Attribute[](0)));
    }

    // -------------------------------------------------------------------------
    // extend_expiry
    // -------------------------------------------------------------------------

    function test_extend_anchorsAtCurrentBlock() public {
        EntityKey key = createDefault(); // expires at 150
        vm.roll(120);

        vm.expectEmit();
        emit EntityV2.ExpiryExtended(key, alice, BlockNumber.wrap(220), bytes32(0), BlockNumber.wrap(150), alice);
        vm.prank(alice);
        executeOne(extendOp(key, 100)); // 120 + 100 = 220

        assertEq(BlockNumber.unwrap(client.commitment(key).expiresAt), 220);
    }

    function test_extend_notIncreasing_reverts() public {
        EntityKey key = createDefault(); // expires at 150
        vm.expectRevert(
            abi.encodeWithSelector(
                EntityV2.ExpiryNotExtended.selector, key, BlockNumber.wrap(110), BlockNumber.wrap(150)
            )
        );
        vm.prank(alice);
        executeOne(extendOp(key, 10)); // 100 + 10 = 110 < 150
    }

    function test_extend_permissionless_allowsAnyCaller() public {
        EntityKey key = client.entityKey(alice, 0);
        vm.prank(alice);
        executeOne(createOp(50, EntityV2.FLAG_PERMISSIONLESS_EXTENSION, new EntityV2.Attribute[](0)));

        vm.expectEmit();
        emit EntityV2.ExpiryExtended(key, alice, BlockNumber.wrap(200), bytes32(0), BlockNumber.wrap(150), bob);
        vm.prank(bob);
        executeOne(extendOp(key, 100));
    }

    function test_extend_notOwner_reverts() public {
        EntityKey key = createDefault();
        vm.expectRevert(abi.encodeWithSelector(EntityV2.NotOwner.selector, key, bob, alice));
        vm.prank(bob);
        executeOne(extendOp(key, 100));
    }

    // -------------------------------------------------------------------------
    // transfer_ownership
    // -------------------------------------------------------------------------

    function test_transfer_changesOwner() public {
        EntityKey key = createDefault();

        vm.expectEmit();
        emit EntityV2.OwnershipTransferred(key, bob, BlockNumber.wrap(150), bytes32(0), alice);
        vm.prank(alice);
        executeOne(transferOp(key, bob));

        assertEq(client.commitment(key).owner, bob);

        // Previous owner loses patch rights.
        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](1);
        mutations[0] = attr(COLOR, EntityV2.TYPE_STRING, "blue");
        vm.expectRevert(abi.encodeWithSelector(EntityV2.NotOwner.selector, key, alice, bob));
        vm.prank(alice);
        executeOne(patchOp(key, mutations));
    }

    function test_transfer_toSelf_reverts() public {
        EntityKey key = createDefault();
        vm.expectRevert(abi.encodeWithSelector(EntityV2.TransferToSelf.selector, key));
        vm.prank(alice);
        executeOne(transferOp(key, alice));
    }

    function test_transfer_toZero_reverts() public {
        EntityKey key = createDefault();
        vm.expectRevert(abi.encodeWithSelector(EntityV2.TransferToZeroAddress.selector, key));
        vm.prank(alice);
        executeOne(transferOp(key, address(0)));
    }

    // -------------------------------------------------------------------------
    // delete
    // -------------------------------------------------------------------------

    function test_delete_removesCommitment() public {
        EntityKey key = createDefault();

        vm.expectEmit();
        emit EntityV2.EntityDeleted(key, alice, BlockNumber.wrap(150), bytes32(0));
        vm.prank(alice);
        executeOne(deleteOp(key));

        assertEq(client.commitment(key).creator, address(0));
    }

    function test_delete_notOwner_reverts() public {
        EntityKey key = createDefault();
        vm.expectRevert(abi.encodeWithSelector(EntityV2.NotOwner.selector, key, bob, alice));
        vm.prank(bob);
        executeOne(deleteOp(key));
    }

    // -------------------------------------------------------------------------
    // expiry predicate
    // -------------------------------------------------------------------------

    function test_expired_rejectsEveryOp() public {
        EntityKey key = createDefault(); // expires at 150
        vm.roll(150); // expiresAt <= current → expired; last live block was 149

        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](1);
        mutations[0] = attr(COLOR, EntityV2.TYPE_STRING, "blue");
        bytes memory notActive = abi.encodeWithSelector(EntityV2.EntityNotActive.selector, key, BlockNumber.wrap(150));

        vm.startPrank(alice);
        vm.expectRevert(notActive);
        executeOne(patchOp(key, mutations));
        vm.expectRevert(notActive);
        executeOne(extendOp(key, 100));
        vm.expectRevert(notActive);
        executeOne(transferOp(key, bob));
        vm.expectRevert(notActive);
        executeOne(deleteOp(key));
        vm.stopPrank();
    }

    function test_lastLiveBlock_isExpiresAtMinusOne() public {
        EntityKey key = createDefault(); // expires at 150
        vm.roll(149);
        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](1);
        mutations[0] = attr(COLOR, EntityV2.TYPE_STRING, "blue");
        vm.prank(alice);
        executeOne(patchOp(key, mutations)); // still live at 149
    }

    // -------------------------------------------------------------------------
    // readonly
    // -------------------------------------------------------------------------

    function test_readonly_allowsOnlyExtend() public {
        EntityKey key = client.entityKey(alice, 0);
        vm.prank(alice);
        executeOne(createOp(50, EntityV2.FLAG_READONLY, threeAttrs()));

        bytes memory readonlyErr = abi.encodeWithSelector(EntityV2.EntityReadonly.selector, key);
        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](1);
        mutations[0] = attr(COLOR, EntityV2.TYPE_STRING, "blue");

        vm.startPrank(alice);
        vm.expectRevert(readonlyErr);
        executeOne(patchOp(key, mutations));
        vm.expectRevert(readonlyErr);
        executeOne(transferOp(key, bob));
        vm.expectRevert(readonlyErr);
        executeOne(deleteOp(key));

        executeOne(extendOp(key, 100)); // extend stays permitted
        vm.stopPrank();
        assertEq(BlockNumber.unwrap(client.commitment(key).expiresAt), 200);
    }

    // -------------------------------------------------------------------------
    // custom attribute enumeration
    // -------------------------------------------------------------------------

    function assertNames(EntityKey key, Ident32[] memory expected) internal view {
        Ident32[] memory names = client.customAttributeNames(key);
        assertEq(names.length, expected.length);
        for (uint256 i = 0; i < names.length; i++) {
            assertEq(Ident32.unwrap(names[i]), Ident32.unwrap(expected[i]));
        }
        assertEq(client.commitment(key).customAttributes, uint16(names.length));
    }

    function test_customAttributeNames_afterCreate() public {
        EntityKey key = createDefault(); // custom attrs: [color]
        Ident32[] memory expected = new Ident32[](1);
        expected[0] = COLOR;
        assertNames(key, expected);
    }

    function test_customAttributeNames_sortedInsertAndRemove() public {
        EntityKey key = createDefault(); // [color]

        // Sorted mutations: "alpha" < "color" (tombstone) < "size" < "zoom".
        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](4);
        mutations[0] = attr(encodeIdent32("alpha"), EntityV2.TYPE_BOOL, abi.encode(true));
        mutations[1] = attr(COLOR, EntityV2.TYPE_TOMBSTONE, "");
        mutations[2] = attr(SIZE, EntityV2.TYPE_U256, abi.encode(uint256(1)));
        mutations[3] = attr(encodeIdent32("zoom"), EntityV2.TYPE_BOOL, abi.encode(false));

        vm.prank(alice);
        executeOne(patchOp(key, mutations));

        Ident32[] memory expected = new Ident32[](3);
        expected[0] = encodeIdent32("alpha");
        expected[1] = SIZE;
        expected[2] = encodeIdent32("zoom");
        assertNames(key, expected);
    }

    function test_customAttributeNames_insertBetweenExisting() public {
        EntityKey key = createDefault(); // [color]

        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](1);
        mutations[0] = attr(SIZE, EntityV2.TYPE_U256, abi.encode(uint256(1)));
        vm.prank(alice);
        executeOne(patchOp(key, mutations)); // [color, size]

        mutations[0] = attr(encodeIdent32("depth"), EntityV2.TYPE_U256, abi.encode(uint256(2)));
        vm.prank(alice);
        executeOne(patchOp(key, mutations)); // insert between → [color, depth, size]

        Ident32[] memory expected = new Ident32[](3);
        expected[0] = COLOR;
        expected[1] = encodeIdent32("depth");
        expected[2] = SIZE;
        assertNames(key, expected);
    }

    function test_customAttributeNames_deleteClears() public {
        EntityKey key = createDefault();
        vm.prank(alice);
        executeOne(deleteOp(key));
        assertEq(client.customAttributeNames(key).length, 0);
    }

    // -------------------------------------------------------------------------
    // batch semantics
    // -------------------------------------------------------------------------

    function test_batch_createThenPatchPrecomputedKey() public {
        EntityKey key = client.entityKey(alice, 0);

        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](1);
        mutations[0] = attr(SIZE, EntityV2.TYPE_U256, abi.encode(uint256(7)));

        EntityV2.Operation[] memory ops = new EntityV2.Operation[](2);
        ops[0] = createOp(50, 0, threeAttrs());
        ops[1] = patchOp(key, mutations);

        vm.prank(alice);
        EntityKey[] memory keys = client.execute(ops);

        assertEq(EntityKey.unwrap(keys[0]), EntityKey.unwrap(key));
        assertEq(EntityKey.unwrap(keys[1]), EntityKey.unwrap(key));
        assertEq(client.commitment(key).customAttributes, 2);
    }

    function test_batch_atomic_revertRollsBackAll() public {
        EntityKey key = client.entityKey(alice, 0);

        EntityV2.Operation[] memory ops = new EntityV2.Operation[](2);
        ops[0] = createOp(50, 0, threeAttrs());
        ops[1] = extendOp(key, 10); // 100 + 10 = 110 < 150 → reverts

        vm.expectRevert(
            abi.encodeWithSelector(
                EntityV2.ExpiryNotExtended.selector, key, BlockNumber.wrap(110), BlockNumber.wrap(150)
            )
        );
        vm.prank(alice);
        client.execute(ops);

        assertEq(client.commitment(key).creator, address(0));
        assertEq(client.nonces(alice), 0);
    }

    function test_emptyBatch_reverts() public {
        vm.expectRevert(EntityV2.EmptyBatch.selector);
        client.execute(new EntityV2.Operation[](0));
    }

    // -------------------------------------------------------------------------
    // storage & config: RecordStore access control, ProtocolParams limits
    // -------------------------------------------------------------------------

    function test_store_onlyEngineWrites() public {
        RecordStore store = client.STORE();
        assertEq(store.ENGINE(), address(client));
        EntityKey key = client.entityKey(alice, 0);
        vm.expectRevert(abi.encodeWithSelector(RecordStore.OnlyEngine.selector, address(this)));
        store.putCell(EntityKey.unwrap(key), RecordReader.Cell({name: COLOR, typeId: EntityV2.TYPE_STRING, value: "x"}));
    }

    function test_budgetExceeded_reverts() public {
        EntityV2.Costs memory costs = EntityV2.defaultCosts();
        costs.executeBase = type(uint64).max; // exceeds any gasleft-bound budget
        ExecutionClient expensive =
            new ExecutionClient(new ProtocolParams(EntityV2.defaultLimits(), costs, testConstants()));

        EntityV2.Operation[] memory ops = new EntityV2.Operation[](1);
        ops[0] = createOp(10, 0, new EntityV2.Attribute[](0));
        // Budget is bound to gasleft(), so the exact revert args vary.
        vm.expectPartialRevert(EntityV2.BudgetExceeded.selector);
        vm.prank(alice);
        expensive.execute(ops);
    }

    function test_payloadAboveMax_reverts() public {
        uint256 max = EntityV2.MAX_PAYLOAD_BYTES;
        EntityV2.Attribute[] memory attrs = new EntityV2.Attribute[](1);
        attrs[0] = attr(PAYLOAD, EntityV2.TYPE_BYTES, new bytes(max + 1));
        vm.expectRevert(
            abi.encodeWithSelector(EntityV2.MaxValueLengthExceeded.selector, PAYLOAD, EntityV2.TYPE_BYTES, max, max + 1)
        );
        vm.prank(alice);
        executeOne(createOp(10, 0, attrs));
    }

    function test_store_keyCellIsFirst() public {
        EntityKey key = createDefault();
        Ident32[] memory names = client.STORE().cellNames(EntityKey.unwrap(key));
        assertEq(Ident32.unwrap(names[0]), client.STORE().KEY_CELL_NAME());
    }

    function test_recordTypes_assigned() public {
        EntityKey key = createDefault();
        assertEq(client.STORE().recordType(EntityKey.unwrap(key)), EntityV2.RECORD_TYPE_ENTITY);
        bytes32 nonceRecord = keccak256(abi.encodePacked(bytes32("arkiv/nonce"), alice));
        assertEq(client.STORE().recordType(nonceRecord), EntityV2.RECORD_TYPE_ACCOUNT);
    }

    function test_nonEntityRecordKey_asEntityKey_reverts() public {
        createDefault(); // creates alice's nonce record as a side effect
        bytes32 nonceRecord = keccak256(abi.encodePacked(bytes32("arkiv/nonce"), alice));

        vm.expectRevert(
            abi.encodeWithSelector(
                EntityV2.RecordTypeMismatch.selector,
                nonceRecord,
                EntityV2.RECORD_TYPE_ENTITY,
                EntityV2.RECORD_TYPE_ACCOUNT
            )
        );
        vm.prank(alice);
        executeOne(deleteOp(EntityKey.wrap(nonceRecord)));

        // The public view treats it as a nonexistent entity.
        assertEq(client.commitment(EntityKey.wrap(nonceRecord)).creator, address(0));
    }

    function test_patch_perEntityCustomCap_enforced() public {
        EntityV2.Limits memory limits = EntityV2.defaultLimits();
        limits.maxAttributes = 2;
        ExecutionClient tight =
            new ExecutionClient(new ProtocolParams(limits, EntityV2.defaultCosts(), testConstants()));

        // Create with 1 custom attribute (list cap is 2).
        EntityKey key = tight.entityKey(alice, 0);
        EntityV2.Attribute[] memory attrs = new EntityV2.Attribute[](1);
        attrs[0] = attr(COLOR, EntityV2.TYPE_STRING, "red");
        EntityV2.Operation[] memory ops = new EntityV2.Operation[](1);
        ops[0] = createOp(50, 0, attrs);
        vm.prank(alice);
        tight.execute(ops);

        // Patch adds 2 more customs → 3 total > per-entity cap 2.
        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](2);
        mutations[0] = attr(encodeIdent32("alpha"), EntityV2.TYPE_BOOL, abi.encode(true));
        mutations[1] = attr(SIZE, EntityV2.TYPE_U256, abi.encode(uint256(1)));
        ops[0] = patchOp(key, mutations);

        vm.expectRevert(abi.encodeWithSelector(EntityV2.TooManyAttributes.selector, 3, 2));
        vm.prank(alice);
        tight.execute(ops);
    }

    function test_limits_probedFromProtocolParams() public {
        EntityV2.Limits memory limits = EntityV2.defaultLimits();
        limits.maxMutations = 2;
        ExecutionClient tight =
            new ExecutionClient(new ProtocolParams(limits, EntityV2.defaultCosts(), testConstants()));

        EntityKey key = tight.entityKey(alice, 0);
        EntityV2.Operation[] memory ops = new EntityV2.Operation[](1);
        ops[0] = createOp(50, 0, threeAttrs());
        vm.prank(alice);
        tight.execute(ops);

        // Sorted: "alpha" < "color" < "size" — 3 mutations > maxMutations 2.
        EntityV2.Attribute[] memory mutations = new EntityV2.Attribute[](3);
        mutations[0] = attr(encodeIdent32("alpha"), EntityV2.TYPE_BOOL, abi.encode(true));
        mutations[1] = attr(COLOR, EntityV2.TYPE_STRING, "blue");
        mutations[2] = attr(SIZE, EntityV2.TYPE_U256, abi.encode(uint256(1)));
        ops[0] = patchOp(key, mutations);

        vm.expectRevert(abi.encodeWithSelector(EntityV2.TooManyMutations.selector, 3, 2));
        vm.prank(alice);
        tight.execute(ops);
    }

    function test_unknownOperation_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(EntityV2.InvalidOperation.selector, uint8(99)));
        executeOne(op(99, ""));
    }
}
