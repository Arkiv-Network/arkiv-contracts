// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../../src/BlockNumber.sol";
import {Base} from "../../utils/Base.t.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";

contract CreateTest is Base {
    BlockNumber expiresAt;

    function setUp() public override {
        super.setUp();
        expiresAt = currentBlock() + BlockNumber.wrap(1000);
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _defaultOp() internal view returns (EntityHashing.Op memory) {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        return Lib.createOp("hello", "text/plain", attrs, expiresAt);
    }

    function _defaultOpWithAttrs(EntityHashing.Attribute[] memory attrs)
        internal
        view
        returns (EntityHashing.Op memory)
    {
        return Lib.createOp("hello", "text/plain", attrs, expiresAt);
    }

    // =========================================================================
    // Validation — attribute count
    // =========================================================================

    function test_create_tooManyAttributes_reverts() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](33);
        for (uint256 i = 0; i < 33; i++) {
            bytes memory name = new bytes(1);
            name[0] = bytes1(uint8(0x41 + i));
            attrs[i] = Lib.uintAttr(string(name), i);
        }

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.TooManyAttributes.selector, 33, 32));
        registry.exposed_create(op);
    }

    function test_create_maxAttributes_succeeds() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](32);
        for (uint256 i = 0; i < 32; i++) {
            bytes memory name = new bytes(1);
            name[0] = bytes1(uint8(0x41 + i));
            attrs[i] = Lib.uintAttr(string(name), i);
        }

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);
        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);
        assertTrue(key != bytes32(0));
    }

    // =========================================================================
    // Validation — empty attribute name
    // =========================================================================

    function test_create_emptyAttributeName_reverts() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = EntityHashing.Attribute({
            name: bytes32(0), valueType: EntityHashing.ATTR_UINT, value: abi.encode(uint256(1))
        });

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);
        vm.prank(alice);
        vm.expectRevert(EntityHashing.AttributesNotSorted.selector);
        registry.exposed_create(op);
    }

    // =========================================================================
    // Validation — attribute sort order
    // =========================================================================

    function test_create_duplicateAttributeNames_reverts() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = Lib.uintAttr("aaa", 1);
        attrs[1] = Lib.uintAttr("aaa", 2);

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);
        vm.prank(alice);
        vm.expectRevert(EntityHashing.AttributesNotSorted.selector);
        registry.exposed_create(op);
    }

    function test_create_unsortedAttributes_reverts() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = Lib.uintAttr("bbb", 1);
        attrs[1] = Lib.uintAttr("aaa", 2);

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);
        vm.prank(alice);
        vm.expectRevert(EntityHashing.AttributesNotSorted.selector);
        registry.exposed_create(op);
    }

    function test_create_sortedAttributes_succeeds() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = Lib.uintAttr("aaa", 1);
        attrs[1] = Lib.uintAttr("bbb", 2);

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);
        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);
        assertTrue(key != bytes32(0));
    }

    // =========================================================================
    // Validation — value type/length (via attributeHash)
    // =========================================================================

    function test_create_stringAttrTooLarge_reverts() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = EntityHashing.Attribute({
            name: Lib.packName("aaa"), valueType: EntityHashing.ATTR_STRING, value: new bytes(1025)
        });

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);
        vm.prank(alice);
        vm.expectRevert(); // InvalidValueLength
        registry.exposed_create(op);
    }

    function test_create_stringAttrAtMaxSize_succeeds() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = EntityHashing.Attribute({
            name: Lib.packName("aaa"), valueType: EntityHashing.ATTR_STRING, value: new bytes(1024)
        });

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);
        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);
        assertTrue(key != bytes32(0));
    }

    function test_create_uintAttrWrongLength_reverts() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] =
            EntityHashing.Attribute({name: Lib.packName("aaa"), valueType: EntityHashing.ATTR_UINT, value: hex"01"});

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);
        vm.prank(alice);
        vm.expectRevert(); // InvalidValueLength
        registry.exposed_create(op);
    }

    function test_create_invalidValueType_reverts() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = EntityHashing.Attribute({name: Lib.packName("aaa"), valueType: 99, value: hex"00"});

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);
        vm.prank(alice);
        vm.expectRevert(); // InvalidValueType
        registry.exposed_create(op);
    }

    // =========================================================================
    // Validation — expiry
    // =========================================================================

    function test_create_expiryEqualToCurrentBlock_reverts() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, currentBlock());

        vm.prank(alice);
        vm.expectRevert(); // ExpiryInPast
        registry.exposed_create(op);
    }

    function test_create_expiryInPast_reverts() public {
        vm.roll(block.number + 100);

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, BlockNumber.wrap(1));

        vm.prank(alice);
        vm.expectRevert(); // ExpiryInPast
        registry.exposed_create(op);
    }

    function test_create_expiryOneBlockAhead_succeeds() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, currentBlock() + BlockNumber.wrap(1));

        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);
        assertTrue(key != bytes32(0));
    }

    // =========================================================================
    // State — commitment
    // =========================================================================

    function test_create_storesCommitment() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);

        EntityHashing.Commitment memory c = registry.getCommitment(key);
        assertEq(c.creator, alice);
        assertEq(c.owner, alice);
        assertEq(BlockNumber.unwrap(c.createdAt), uint32(block.number));
        assertEq(BlockNumber.unwrap(c.updatedAt), uint32(block.number));
        assertEq(BlockNumber.unwrap(c.expiresAt), BlockNumber.unwrap(expiresAt));
        assertTrue(c.coreHash != bytes32(0));
    }

    // =========================================================================
    // State — nonce
    // =========================================================================

    function test_create_incrementsNonce() public {
        assertEq(registry.nonces(alice), 0);

        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        registry.exposed_create(op);
        assertEq(registry.nonces(alice), 1);

        vm.prank(alice);
        registry.exposed_create(op);
        assertEq(registry.nonces(alice), 2);
    }

    function test_create_independentNoncesPerSender() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        registry.exposed_create(op);

        vm.prank(bob);
        registry.exposed_create(op);

        assertEq(registry.nonces(alice), 1);
        assertEq(registry.nonces(bob), 1);
    }

    // =========================================================================
    // State — entity key determinism
    // =========================================================================

    function test_create_keyMatchesEntityKeyFunction() public {
        bytes32 expectedKey = registry.entityKey(alice, 0);

        EntityHashing.Op memory op = _defaultOp();
        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);

        assertEq(key, expectedKey);
    }

    function test_create_secondKeyMatchesNonce1() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        registry.exposed_create(op);

        bytes32 expectedKey = registry.entityKey(alice, 1);
        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);

        assertEq(key, expectedKey);
    }

    function test_create_differentSenders_differentKeys() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        (bytes32 keyAlice,) = registry.exposed_create(op);

        vm.prank(bob);
        (bytes32 keyBob,) = registry.exposed_create(op);

        assertNotEq(keyAlice, keyBob);
    }

    // =========================================================================
    // Event
    // =========================================================================

    function test_create_emitsEntityCreated() public {
        EntityHashing.Op memory op = _defaultOp();
        bytes32 expectedKey = registry.entityKey(alice, 0);

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit EntityCreated(expectedKey, alice, bytes32(0), expiresAt);
        registry.exposed_create(op);
    }

    event EntityCreated(bytes32 indexed entityKey, address indexed owner, bytes32 entityHash, BlockNumber expiresAt);

    // =========================================================================
    // Hash correctness
    // =========================================================================

    function test_create_coreHashMatchesManualComputation() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = Lib.uintAttr("count", 42);
        EntityHashing.Op memory op = Lib.createOp("hello", "text/plain", attrs, expiresAt);

        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);

        EntityHashing.Commitment memory c = registry.getCommitment(key);

        bytes32 expected = registry.exposed_coreHash(key, alice, c.createdAt, "text/plain", "hello", attrs);
        assertEq(c.coreHash, expected);
    }

    function test_create_entityHashMatchesManualComputation() public {
        EntityHashing.Op memory op = _defaultOp();

        vm.prank(alice);
        (bytes32 key, bytes32 entityHash_) = registry.exposed_create(op);

        EntityHashing.Commitment memory c = registry.getCommitment(key);

        bytes32 expected = registry.exposed_entityHash(c.coreHash, alice, c.updatedAt, c.expiresAt);
        assertEq(entityHash_, expected);
    }

    // =========================================================================
    // Edge cases
    // =========================================================================

    function test_create_emptyPayloadAndAttributes() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        EntityHashing.Op memory op = Lib.createOp("", "text/plain", attrs, expiresAt);

        vm.prank(alice);
        (bytes32 key, bytes32 entityHash_) = registry.exposed_create(op);

        assertTrue(key != bytes32(0));
        assertTrue(entityHash_ != bytes32(0));
    }

    function test_create_allThreeAttributeTypes() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](3);
        attrs[0] = Lib.entityKeyAttr("aaa", keccak256("ref"));
        attrs[1] = Lib.stringAttr("bbb", "value");
        attrs[2] = Lib.uintAttr("ccc", 99);

        EntityHashing.Op memory op = _defaultOpWithAttrs(attrs);

        vm.prank(alice);
        (bytes32 key,) = registry.exposed_create(op);

        EntityHashing.Commitment memory c = registry.getCommitment(key);
        assertTrue(c.coreHash != bytes32(0));
    }
}
