// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BlockNumber} from "../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Entity} from "../../src/Entity.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";

/// @dev Tests _wrapEntityHash in isolation — verifies domain-wrapped
/// EIP-712 entity struct hash matches manual computation.
contract WrapEntityHashTest is Test, EntityRegistry {
    address alice = makeAddr("alice");

    function doWrap(bytes32 coreHash_, address owner, BlockNumber updatedAt, BlockNumber expiresAt)
        external
        view
        returns (bytes32)
    {
        return _wrapEntityHash(coreHash_, owner, updatedAt, expiresAt);
    }

    // =========================================================================
    // Correctness — matches manual domain wrapping
    // =========================================================================

    function test_matchesManualDomainWrapping() public {
        bytes32 coreHash_ = keccak256("core");
        BlockNumber updatedAt = BlockNumber.wrap(100);
        BlockNumber expiresAt = BlockNumber.wrap(500);

        bytes32 structHash = Entity.entityStructHash(coreHash_, alice, updatedAt, expiresAt);
        bytes32 expected = _hashTypedDataV4(structHash);

        assertEq(this.doWrap(coreHash_, alice, updatedAt, expiresAt), expected);
    }

    // =========================================================================
    // Determinism
    // =========================================================================

    function test_deterministic() public {
        bytes32 coreHash_ = keccak256("core");
        BlockNumber updatedAt = BlockNumber.wrap(100);
        BlockNumber expiresAt = BlockNumber.wrap(500);

        assertEq(
            this.doWrap(coreHash_, alice, updatedAt, expiresAt), this.doWrap(coreHash_, alice, updatedAt, expiresAt)
        );
    }

    // =========================================================================
    // Different inputs produce different hashes
    // =========================================================================

    function test_differentCoreHash_differs() public {
        BlockNumber updatedAt = BlockNumber.wrap(100);
        BlockNumber expiresAt = BlockNumber.wrap(500);

        assertNotEq(
            this.doWrap(keccak256("a"), alice, updatedAt, expiresAt),
            this.doWrap(keccak256("b"), alice, updatedAt, expiresAt)
        );
    }

    function test_differentOwner_differs() public {
        bytes32 coreHash_ = keccak256("core");
        BlockNumber updatedAt = BlockNumber.wrap(100);
        BlockNumber expiresAt = BlockNumber.wrap(500);
        address bob = makeAddr("bob");

        assertNotEq(
            this.doWrap(coreHash_, alice, updatedAt, expiresAt), this.doWrap(coreHash_, bob, updatedAt, expiresAt)
        );
    }

    function test_differentUpdatedAt_differs() public {
        bytes32 coreHash_ = keccak256("core");
        BlockNumber expiresAt = BlockNumber.wrap(500);

        assertNotEq(
            this.doWrap(coreHash_, alice, BlockNumber.wrap(100), expiresAt),
            this.doWrap(coreHash_, alice, BlockNumber.wrap(200), expiresAt)
        );
    }

    function test_differentExpiresAt_differs() public {
        bytes32 coreHash_ = keccak256("core");
        BlockNumber updatedAt = BlockNumber.wrap(100);

        assertNotEq(
            this.doWrap(coreHash_, alice, updatedAt, BlockNumber.wrap(500)),
            this.doWrap(coreHash_, alice, updatedAt, BlockNumber.wrap(600))
        );
    }

    // =========================================================================
    // Fuzz
    // =========================================================================

    function test_fuzz(bytes32 coreHash_, address owner, uint32 rawUpdatedAt, uint32 rawExpiresAt) public {
        BlockNumber updatedAt = BlockNumber.wrap(rawUpdatedAt);
        BlockNumber expiresAt = BlockNumber.wrap(rawExpiresAt);

        bytes32 expected = _hashTypedDataV4(Entity.entityStructHash(coreHash_, owner, updatedAt, expiresAt));
        assertEq(this.doWrap(coreHash_, owner, updatedAt, expiresAt), expected);
    }
}
