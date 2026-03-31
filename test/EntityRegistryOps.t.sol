// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../src/BlockNumber.sol";
import {ShortStrings} from "@openzeppelin/contracts/utils/ShortStrings.sol";
import {EntityRegistryBase} from "./EntityRegistryBase.t.sol";
import {EntityRegistry} from "../src/EntityRegistry.sol";

contract EntityRegistryOpsTest is EntityRegistryBase {
    using ShortStrings for *;

    BlockNumber expiresAt = BlockNumber.wrap(1000);

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    function _createOp(bytes memory payload, BlockNumber _expiresAt) internal pure returns (EntityRegistry.Op memory) {
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);
        return EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: payload,
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: _expiresAt
        });
    }

    function _createOpWithAttrs(bytes memory payload, EntityRegistry.Attribute[] memory attrs, BlockNumber _expiresAt)
        internal
        pure
        returns (EntityRegistry.Op memory)
    {
        return EntityRegistry.Op({
            opType: EntityRegistry.OpType.CREATE,
            entityKey: bytes32(0),
            payload: payload,
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: _expiresAt
        });
    }

    function _updateOp(bytes32 key, bytes memory payload) internal pure returns (EntityRegistry.Op memory) {
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);
        return EntityRegistry.Op({
            opType: EntityRegistry.OpType.UPDATE,
            entityKey: key,
            payload: payload,
            contentType: "text/plain",
            attributes: attrs,
            expiresAt: BlockNumber.wrap(0)
        });
    }

    function _extendOp(bytes32 key, BlockNumber _expiresAt) internal pure returns (EntityRegistry.Op memory) {
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);
        return EntityRegistry.Op({
            opType: EntityRegistry.OpType.EXTEND,
            entityKey: key,
            payload: "",
            contentType: "",
            attributes: attrs,
            expiresAt: _expiresAt
        });
    }

    function _deleteOp(bytes32 key) internal pure returns (EntityRegistry.Op memory) {
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);
        return EntityRegistry.Op({
            opType: EntityRegistry.OpType.DELETE,
            entityKey: key,
            payload: "",
            contentType: "",
            attributes: attrs,
            expiresAt: BlockNumber.wrap(0)
        });
    }

    function _executeSingle(EntityRegistry.Op memory singleOp) internal {
        EntityRegistry.Op[] memory ops = new EntityRegistry.Op[](1);
        ops[0] = singleOp;
        registry.execute(ops);
    }

    function _createEntity(address sender) internal returns (bytes32 key) {
        uint32 nonce = registry.nonces(sender);
        key = registry.entityKey(sender, nonce);
        vm.prank(sender);
        _executeSingle(_createOp("hello", expiresAt));
    }

    // -------------------------------------------------------------------------
    // CREATE — happy path
    // -------------------------------------------------------------------------

    function test_create_storesEntity() public {
        // GIVEN alice creates an entity
        bytes32 key = _createEntity(alice);

        // THEN the entity is stored with correct fields
        (
            address creator,
            BlockNumber createdAt,
            BlockNumber updatedAt,
            BlockNumber _expiresAt,
            address owner,
            bytes32 _coreHash
        ) = registry.entities(key);
        assertEq(creator, alice);
        assertEq(owner, alice);
        assertEq(BlockNumber.unwrap(createdAt), block.number);
        assertEq(BlockNumber.unwrap(updatedAt), block.number);
        assertEq(BlockNumber.unwrap(_expiresAt), BlockNumber.unwrap(expiresAt));
        assertNotEq(_coreHash, bytes32(0));
    }

    function test_create_incrementsNonce() public {
        // GIVEN alice's nonce is 0
        assertEq(registry.nonces(alice), 0);

        // WHEN alice creates an entity
        _createEntity(alice);

        // THEN nonce is incremented
        assertEq(registry.nonces(alice), 1);
    }

    function test_create_entityKeyMatchesPrediction() public {
        // GIVEN alice predicts her next entity key
        bytes32 predicted = registry.entityKey(alice, registry.nonces(alice));

        // WHEN she creates
        bytes32 actual = _createEntity(alice);

        // THEN it matches
        assertEq(actual, predicted);
    }

    function test_create_emitsEvent() public {
        // GIVEN we can predict the full event data
        uint32 nonce = registry.nonces(alice);
        bytes32 key = registry.entityKey(alice, nonce);
        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);
        bytes32 _coreHash = registry.coreHash(key, alice, uint32(block.number), "text/plain", "hello", attrs);
        bytes32 _entityHash = registry.entityHash(_coreHash, alice, uint32(block.number), BlockNumber.unwrap(expiresAt));

        // THEN the full event is emitted with correct data
        vm.expectEmit(true, true, true, true);
        emit EntityRegistry.EntityCreated(key, alice, _entityHash, expiresAt);

        vm.prank(alice);
        _executeSingle(_createOp("hello", expiresAt));
    }

    function test_create_updatesChangeSetHash() public {
        // GIVEN a fresh registry
        bytes32 hashBefore = registry.changeSetHash();
        assertEq(hashBefore, bytes32(0));

        // WHEN an entity is created
        _createEntity(alice);

        // THEN changeSetHash is updated
        assertNotEq(registry.changeSetHash(), bytes32(0));
    }

    function test_create_expiryInPast_reverts() public {
        // GIVEN an expiresAt in the past
        BlockNumber pastExpiry = BlockNumber.wrap(uint32(block.number));

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.ExpiryInPast.selector, pastExpiry, currentBlock()));
        _executeSingle(_createOp("hello", pastExpiry));
    }

    // -------------------------------------------------------------------------
    // UPDATE — happy path
    // -------------------------------------------------------------------------

    function test_update_changesCoreHash() public {
        // GIVEN an entity created by alice
        bytes32 key = _createEntity(alice);
        (,,,,, bytes32 oldCoreHash) = registry.entities(key);

        // WHEN alice updates it
        vm.prank(alice);
        _executeSingle(_updateOp(key, "updated payload"));

        // THEN coreHash changes
        (,,,,, bytes32 newCoreHash) = registry.entities(key);
        assertNotEq(newCoreHash, oldCoreHash);
    }

    function test_update_updatesUpdatedAt() public {
        // GIVEN an entity
        bytes32 key = _createEntity(alice);

        // WHEN time advances and alice updates
        vm.roll(block.number + 10);
        vm.prank(alice);
        _executeSingle(_updateOp(key, "new"));

        // THEN updatedAt reflects the new block
        (,, BlockNumber updatedAt,,,) = registry.entities(key);
        assertEq(BlockNumber.unwrap(updatedAt), block.number);
    }

    function test_update_notOwner_reverts() public {
        // GIVEN an entity owned by alice
        bytes32 key = _createEntity(alice);

        // WHEN bob tries to update
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.NotOwner.selector, key, bob, alice));
        _executeSingle(_updateOp(key, "hacked"));
    }

    function test_update_entityNotFound_reverts() public {
        bytes32 fakeKey = keccak256("nonexistent");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.EntityNotFound.selector, fakeKey));
        _executeSingle(_updateOp(fakeKey, "data"));
    }

    function test_update_expired_reverts() public {
        // GIVEN an entity that expires at block 1000
        bytes32 key = _createEntity(alice);

        // WHEN we advance past expiry
        vm.roll(1000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.EntityExpiredError.selector, key, expiresAt));
        _executeSingle(_updateOp(key, "data"));
    }

    // -------------------------------------------------------------------------
    // EXTEND — happy path
    // -------------------------------------------------------------------------

    function test_extend_updatesExpiresAt() public {
        // GIVEN an entity
        bytes32 key = _createEntity(alice);
        BlockNumber newExpiry = BlockNumber.wrap(2000);

        // WHEN alice extends
        vm.prank(alice);
        _executeSingle(_extendOp(key, newExpiry));

        // THEN expiresAt is updated
        (,,, BlockNumber _expiresAt,,) = registry.entities(key);
        assertEq(BlockNumber.unwrap(_expiresAt), 2000);
    }

    function test_extend_doesNotChangeCoreHash() public {
        // GIVEN an entity
        bytes32 key = _createEntity(alice);
        (,,,,, bytes32 originalCoreHash) = registry.entities(key);

        // WHEN alice extends
        vm.prank(alice);
        _executeSingle(_extendOp(key, BlockNumber.wrap(2000)));

        // THEN coreHash is unchanged
        (,,,,, bytes32 afterCoreHash) = registry.entities(key);
        assertEq(afterCoreHash, originalCoreHash);
    }

    function test_extend_notExtended_reverts() public {
        // GIVEN an entity expiring at 1000
        bytes32 key = _createEntity(alice);

        // WHEN alice tries to "extend" to an earlier block
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(EntityRegistry.ExpiryNotExtended.selector, BlockNumber.wrap(500), expiresAt)
        );
        _executeSingle(_extendOp(key, BlockNumber.wrap(500)));
    }

    function test_extend_notOwner_reverts() public {
        bytes32 key = _createEntity(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.NotOwner.selector, key, bob, alice));
        _executeSingle(_extendOp(key, BlockNumber.wrap(2000)));
    }

    // -------------------------------------------------------------------------
    // DELETE — happy path
    // -------------------------------------------------------------------------

    function test_delete_removesEntity() public {
        // GIVEN an entity
        bytes32 key = _createEntity(alice);

        // WHEN alice deletes it
        vm.prank(alice);
        _executeSingle(_deleteOp(key));

        // THEN entity is removed (creator == address(0))
        (address creator,,,,,) = registry.entities(key);
        assertEq(creator, address(0));
    }

    function test_delete_emitsEvent() public {
        bytes32 key = _createEntity(alice);

        // Compute the entityHash before deletion (what the event should contain)
        (,, BlockNumber updatedAt, BlockNumber _expiresAt,, bytes32 _coreHash) = registry.entities(key);
        bytes32 _entityHash =
            registry.entityHash(_coreHash, alice, BlockNumber.unwrap(updatedAt), BlockNumber.unwrap(_expiresAt));

        vm.expectEmit(true, true, true, true);
        emit EntityRegistry.EntityDeleted(key, alice, _entityHash);

        vm.prank(alice);
        _executeSingle(_deleteOp(key));
    }

    function test_delete_notOwner_reverts() public {
        bytes32 key = _createEntity(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.NotOwner.selector, key, bob, alice));
        _executeSingle(_deleteOp(key));
    }

    function test_delete_entityNotFound_reverts() public {
        bytes32 fakeKey = keccak256("nonexistent");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.EntityNotFound.selector, fakeKey));
        _executeSingle(_deleteOp(fakeKey));
    }

    // -------------------------------------------------------------------------
    // EXPIRE
    // -------------------------------------------------------------------------

    function test_expire_removesExpiredEntity() public {
        // GIVEN an entity that expires at block 1000
        bytes32 key = _createEntity(alice);

        // WHEN we advance past expiry and anyone calls expire
        vm.roll(1000);
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        registry.expireEntities(keys);

        // THEN entity is removed
        (address creator,,,,,) = registry.entities(key);
        assertEq(creator, address(0));
    }

    function test_expire_callableByAnyone() public {
        bytes32 key = _createEntity(alice);
        vm.roll(1000);

        // Bob (not the owner) can expire
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.prank(bob);
        registry.expireEntities(keys);

        (address creator,,,,,) = registry.entities(key);
        assertEq(creator, address(0));
    }

    function test_expire_notExpired_reverts() public {
        bytes32 key = _createEntity(alice);

        bytes32[] memory keys = new bytes32[](1);
        keys[0] = key;
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.EntityNotExpired.selector, key, expiresAt));
        registry.expireEntities(keys);
    }

    function test_expire_entityNotFound_reverts() public {
        bytes32 fakeKey = keccak256("nonexistent");
        bytes32[] memory keys = new bytes32[](1);
        keys[0] = fakeKey;
        vm.expectRevert(abi.encodeWithSelector(EntityRegistry.EntityNotFound.selector, fakeKey));
        registry.expireEntities(keys);
    }

    function test_expire_batchMultiple() public {
        // GIVEN two entities
        bytes32 key1 = _createEntity(alice);
        bytes32 key2 = _createEntity(alice);

        // WHEN both expire and we batch-expire
        vm.roll(1000);
        bytes32[] memory keys = new bytes32[](2);
        keys[0] = key1;
        keys[1] = key2;
        registry.expireEntities(keys);

        // THEN both are removed
        (address c1,,,,,) = registry.entities(key1);
        (address c2,,,,,) = registry.entities(key2);
        assertEq(c1, address(0));
        assertEq(c2, address(0));
    }

    // -------------------------------------------------------------------------
    // Batch — mixed operations
    // -------------------------------------------------------------------------

    function test_batch_createThenUpdate() public {
        // GIVEN we predict the entity key
        uint32 nonce = registry.nonces(alice);
        bytes32 key = registry.entityKey(alice, nonce);

        // WHEN alice creates and updates in one batch
        EntityRegistry.Op[] memory ops = new EntityRegistry.Op[](2);
        ops[0] = _createOp("original", expiresAt);
        ops[1] = _updateOp(key, "updated");

        vm.prank(alice);
        registry.execute(ops);

        // THEN entity exists with updated coreHash
        (address creator,,,,, bytes32 _coreHash) = registry.entities(key);
        assertEq(creator, alice);
        assertNotEq(_coreHash, bytes32(0));
    }

    function test_batch_createThenDelete() public {
        uint32 nonce = registry.nonces(alice);
        bytes32 key = registry.entityKey(alice, nonce);

        EntityRegistry.Op[] memory ops = new EntityRegistry.Op[](2);
        ops[0] = _createOp("temp", expiresAt);
        ops[1] = _deleteOp(key);

        vm.prank(alice);
        registry.execute(ops);

        // THEN entity is deleted
        (address creator,,,,,) = registry.entities(key);
        assertEq(creator, address(0));
    }

    function test_batch_atomicity_revertsAll() public {
        // GIVEN alice creates an entity
        bytes32 key = _createEntity(alice);

        // WHEN a batch has a valid delete followed by an invalid update (nonexistent key)
        EntityRegistry.Op[] memory ops = new EntityRegistry.Op[](2);
        ops[0] = _deleteOp(key);
        ops[1] = _updateOp(keccak256("nonexistent"), "data");

        vm.prank(alice);
        vm.expectRevert();
        registry.execute(ops);

        // THEN the entity still exists (delete was rolled back)
        (address creator,,,,,) = registry.entities(key);
        assertEq(creator, alice);
    }

    // -------------------------------------------------------------------------
    // Change set hash — chaining across operations
    // -------------------------------------------------------------------------

    function test_changeSetHash_chainsAcrossOps() public {
        bytes32 hash0 = registry.changeSetHash();
        assertEq(hash0, bytes32(0));

        // Create
        bytes32 key = _createEntity(alice);
        bytes32 hash1 = registry.changeSetHash();
        assertNotEq(hash1, hash0);

        // Update
        vm.prank(alice);
        _executeSingle(_updateOp(key, "v2"));
        bytes32 hash2 = registry.changeSetHash();
        assertNotEq(hash2, hash1);

        // Extend
        vm.prank(alice);
        _executeSingle(_extendOp(key, BlockNumber.wrap(2000)));
        bytes32 hash3 = registry.changeSetHash();
        assertNotEq(hash3, hash2);

        // Delete
        vm.prank(alice);
        _executeSingle(_deleteOp(key));
        bytes32 hash4 = registry.changeSetHash();
        assertNotEq(hash4, hash3);
    }

    // -------------------------------------------------------------------------
    // EXPIRE via executeBatch
    // -------------------------------------------------------------------------

    function test_expire_viaBatch() public {
        bytes32 key = _createEntity(alice);
        vm.roll(1000);

        EntityRegistry.Attribute[] memory attrs = new EntityRegistry.Attribute[](0);
        EntityRegistry.Op[] memory ops = new EntityRegistry.Op[](1);
        ops[0] = EntityRegistry.Op({
            opType: EntityRegistry.OpType.EXPIRE,
            entityKey: key,
            payload: "",
            contentType: "",
            attributes: attrs,
            expiresAt: BlockNumber.wrap(0)
        });

        registry.execute(ops);

        (address creator,,,,,) = registry.entities(key);
        assertEq(creator, address(0));
    }
}
