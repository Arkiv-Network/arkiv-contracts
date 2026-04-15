// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber} from "../../../src/BlockNumber.sol";
import {Ident32} from "../../../src/types/Ident32.sol";
import {Mime128, encodeMime128} from "../../../src/types/Mime128.sol";
import {Test} from "forge-std/Test.sol";
import {Lib} from "../../utils/Lib.sol";
import {EntityHashing} from "../../../src/EntityHashing.sol";
import {EntityRegistry} from "../../../src/EntityRegistry.sol";

contract CoreHashTest is Test, EntityRegistry {
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    Mime128 textPlain;
    Mime128 appJson;

    function setUp() public {
        textPlain = encodeMime128("text/plain");
        appJson = encodeMime128("application/json");
    }

    function hashCore(
        bytes32 key,
        address creator,
        BlockNumber createdAt,
        Mime128 calldata contentType,
        bytes calldata payload,
        EntityHashing.Attribute[] calldata attributes
    ) external pure returns (bytes32) {
        return EntityHashing.coreHash(key, creator, createdAt, contentType, payload, attributes);
    }

    // -------------------------------------------------------------------------
    // Determinism
    // -------------------------------------------------------------------------

    function test_coreHash_deterministic() public {
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](1);
        attrs[0] = Lib.uintAttr("count", 1);

        bytes32 hashA = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", attrs);
        bytes32 hashB = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", attrs);

        assertEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Different inputs produce different hashes
    // -------------------------------------------------------------------------

    function test_coreHash_differentKey_differs() public {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = this.hashCore(keccak256("key1"), alice, BlockNumber.wrap(100), textPlain, "hello", attrs);
        bytes32 hashB = this.hashCore(keccak256("key2"), alice, BlockNumber.wrap(100), textPlain, "hello", attrs);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentCreator_differs() public {
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", attrs);
        bytes32 hashB = this.hashCore(key, bob, BlockNumber.wrap(100), textPlain, "hello", attrs);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentCreatedAt_differs() public {
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", attrs);
        bytes32 hashB = this.hashCore(key, alice, BlockNumber.wrap(200), textPlain, "hello", attrs);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentContentType_differs() public {
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", attrs);
        bytes32 hashB = this.hashCore(key, alice, BlockNumber.wrap(100), appJson, "hello", attrs);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentPayload_differs() public {
        bytes32 key = keccak256("key");
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);

        bytes32 hashA = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", attrs);
        bytes32 hashB = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "world", attrs);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_differentAttributes_differs() public {
        bytes32 key = keccak256("key");

        EntityHashing.Attribute[] memory attrsA = new EntityHashing.Attribute[](1);
        attrsA[0] = Lib.uintAttr("count", 1);

        EntityHashing.Attribute[] memory attrsB = new EntityHashing.Attribute[](1);
        attrsB[0] = Lib.uintAttr("count", 2);

        bytes32 hashA = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", attrsA);
        bytes32 hashB = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", attrsB);

        assertNotEq(hashA, hashB);
    }

    function test_coreHash_emptyVsNonEmptyAttributes_differs() public {
        bytes32 key = keccak256("key");

        EntityHashing.Attribute[] memory empty = new EntityHashing.Attribute[](0);
        EntityHashing.Attribute[] memory one = new EntityHashing.Attribute[](1);
        one[0] = Lib.uintAttr("count", 1);

        bytes32 hashA = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", empty);
        bytes32 hashB = this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", one);

        assertNotEq(hashA, hashB);
    }

    // -------------------------------------------------------------------------
    // Attribute order — unsorted reverts
    // -------------------------------------------------------------------------

    function test_coreHash_unsortedAttributes_reverts() public {
        bytes32 key = keccak256("key");

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = Lib.uintAttr("bbb", 2);
        attrs[1] = Lib.uintAttr("aaa", 1);

        vm.expectRevert(EntityHashing.AttributesNotSorted.selector);
        this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", attrs);
    }

    // -------------------------------------------------------------------------
    // Attribute count — exceeds MAX_ATTRIBUTES
    // -------------------------------------------------------------------------

    function test_coreHash_tooManyAttributes_reverts() public {
        bytes32 key = keccak256("key");
        uint256 count = 33;

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](count);
        for (uint256 i = 0; i < count; i++) {
            // "a", "b", ... sorted single-char names (a–z then a0–a6 won't work;
            // use zero-padded hex strings to guarantee sort order).
            bytes32 name = bytes32(bytes1(uint8(0x61 + i))); // 'a'+i, left-aligned
            bytes32[4] memory v;
            v[0] = bytes32(i);
            attrs[i] = EntityHashing.Attribute({
                name: Ident32.wrap(name),
                valueType: EntityHashing.ATTR_UINT,
                value: v
            });
        }

        vm.expectRevert(abi.encodeWithSelector(EntityHashing.TooManyAttributes.selector, count, 32));
        this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "hello", attrs);
    }

    // -------------------------------------------------------------------------
    // EIP-712 structure — manual encoding match
    // -------------------------------------------------------------------------

    function test_coreHash_matchesManualEIP712Encoding() public {
        bytes32 key = keccak256("key");
        BlockNumber createdAt = BlockNumber.wrap(100);
        bytes memory payload = "hello";

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](2);
        attrs[0] = Lib.uintAttr("aaa", 10);
        attrs[1] = Lib.stringAttr("bbb", "val");

        bytes32 hashA = keccak256(
            abi.encode(
                EntityHashing.ATTRIBUTE_TYPEHASH,
                Ident32.unwrap(attrs[0].name),
                attrs[0].valueType,
                keccak256(abi.encode(attrs[0].value[0], attrs[0].value[1], attrs[0].value[2], attrs[0].value[3]))
            )
        );
        bytes32 hashB = keccak256(
            abi.encode(
                EntityHashing.ATTRIBUTE_TYPEHASH,
                Ident32.unwrap(attrs[1].name),
                attrs[1].valueType,
                keccak256(abi.encode(attrs[1].value[0], attrs[1].value[1], attrs[1].value[2], attrs[1].value[3]))
            )
        );
        bytes32 attrChain = keccak256(abi.encodePacked(bytes32(0), hashA));
        attrChain = keccak256(abi.encodePacked(attrChain, hashB));

        bytes32 ctHash =
            keccak256(abi.encode(textPlain.data[0], textPlain.data[1], textPlain.data[2], textPlain.data[3]));

        bytes32 expected = keccak256(
            abi.encode(EntityHashing.CORE_HASH_TYPEHASH, key, alice, createdAt, ctHash, keccak256(payload), attrChain)
        );

        assertEq(this.hashCore(key, alice, createdAt, textPlain, payload, attrs), expected);
    }

    function test_coreHash_emptyPayloadAndAttributes() public {
        bytes32 key = keccak256("key");

        bytes32 ctHash =
            keccak256(abi.encode(textPlain.data[0], textPlain.data[1], textPlain.data[2], textPlain.data[3]));

        bytes32 expected = keccak256(
            abi.encode(
                EntityHashing.CORE_HASH_TYPEHASH, key, alice, BlockNumber.wrap(100), ctHash, keccak256(""), bytes32(0)
            )
        );

        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        assertEq(this.hashCore(key, alice, BlockNumber.wrap(100), textPlain, "", attrs), expected);
    }
}
