// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../src/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {EntityHashing} from "../../src/EntityHashing.sol";
import {EntityRegistry} from "../../src/EntityRegistry.sol";
import {encodeMime128} from "../../src/types/Mime128.sol";

/// @dev Tests _dispatch routing and invalid-op-type rejection.
/// Each internal op handler is stubbed to record which handler was called,
/// so the test isolates dispatch logic from op behaviour.
contract DispatchTest is Test, EntityRegistry {
    uint8 internal _calledOpType;

    function _stubReturn() internal pure returns (bytes32, bytes32) {
        return (keccak256("key"), keccak256("hash"));
    }

    function _create(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = EntityHashing.CREATE;
        return _stubReturn();
    }

    function _update(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = EntityHashing.UPDATE;
        return _stubReturn();
    }

    function _extend(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = EntityHashing.EXTEND;
        return _stubReturn();
    }

    function _transfer(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = EntityHashing.TRANSFER;
        return _stubReturn();
    }

    function _delete(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = EntityHashing.DELETE;
        return _stubReturn();
    }

    function _expire(EntityHashing.Op calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = EntityHashing.EXPIRE;
        return _stubReturn();
    }

    /// @dev External wrapper so we can call _dispatch via this.doDispatch()
    /// to get calldata encoding.
    function doDispatch(EntityHashing.Op calldata op) external returns (bytes32, bytes32) {
        return _dispatch(op, currentBlock());
    }

    function _op(uint8 opType) internal pure returns (EntityHashing.Op memory) {
        EntityHashing.Attribute[] memory attrs = new EntityHashing.Attribute[](0);
        return EntityHashing.Op({
            opType: opType,
            entityKey: bytes32(0),
            payload: "",
            contentType: encodeMime128("text/plain"),
            attributes: attrs,
            expiresAt: BlockNumber.wrap(0),
            newOwner: address(0)
        });
    }

    // =========================================================================
    // Routing — each op type dispatches to the correct handler
    // =========================================================================

    function test_dispatch_routesCreate() public {
        this.doDispatch(_op(EntityHashing.CREATE));
        assertEq(_calledOpType, EntityHashing.CREATE);
    }

    function test_dispatch_routesUpdate() public {
        this.doDispatch(_op(EntityHashing.UPDATE));
        assertEq(_calledOpType, EntityHashing.UPDATE);
    }

    function test_dispatch_routesExtend() public {
        this.doDispatch(_op(EntityHashing.EXTEND));
        assertEq(_calledOpType, EntityHashing.EXTEND);
    }

    function test_dispatch_routesTransfer() public {
        this.doDispatch(_op(EntityHashing.TRANSFER));
        assertEq(_calledOpType, EntityHashing.TRANSFER);
    }

    function test_dispatch_routesDelete() public {
        this.doDispatch(_op(EntityHashing.DELETE));
        assertEq(_calledOpType, EntityHashing.DELETE);
    }

    function test_dispatch_routesExpire() public {
        this.doDispatch(_op(EntityHashing.EXPIRE));
        assertEq(_calledOpType, EntityHashing.EXPIRE);
    }

    // =========================================================================
    // Invalid op types
    // =========================================================================

    function test_dispatch_opTypeZero_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.InvalidOpType.selector, uint8(0)));
        this.doDispatch(_op(EntityHashing.UNINITIALIZED));
    }

    function test_dispatch_opTypeSeven_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.InvalidOpType.selector, uint8(7)));
        this.doDispatch(_op(7));
    }

    function test_dispatch_opType255_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(EntityHashing.InvalidOpType.selector, uint8(255)));
        this.doDispatch(_op(255));
    }

    // =========================================================================
    // Return values are forwarded from handler
    // =========================================================================

    function test_dispatch_forwardsReturnValues() public {
        (bytes32 key, bytes32 hash) = this.doDispatch(_op(EntityHashing.CREATE));
        assertEq(key, keccak256("key"));
        assertEq(hash, keccak256("hash"));
    }
}
