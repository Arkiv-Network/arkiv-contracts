// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BlockNumber, currentBlock} from "../../src/types/BlockNumber.sol";
import {Test} from "forge-std/Test.sol";
import {Entity} from "../../src/Entity.sol";
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

    function _create(Entity.Operation calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = Entity.CREATE;
        return _stubReturn();
    }

    function _update(Entity.Operation calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = Entity.UPDATE;
        return _stubReturn();
    }

    function _extend(Entity.Operation calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = Entity.EXTEND;
        return _stubReturn();
    }

    function _transfer(Entity.Operation calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = Entity.TRANSFER;
        return _stubReturn();
    }

    function _delete(Entity.Operation calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = Entity.DELETE;
        return _stubReturn();
    }

    function _expire(Entity.Operation calldata, BlockNumber) internal override returns (bytes32, bytes32) {
        _calledOpType = Entity.EXPIRE;
        return _stubReturn();
    }

    /// @dev External wrapper so we can call _dispatch via this.doDispatch()
    /// to get calldata encoding.
    function doDispatch(Entity.Operation calldata op) external returns (bytes32, bytes32) {
        return _dispatch(op, currentBlock());
    }

    function _op(uint8 operationType) internal pure returns (Entity.Operation memory) {
        Entity.Attribute[] memory attrs = new Entity.Attribute[](0);
        return Entity.Operation({
            operationType: operationType,
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
        this.doDispatch(_op(Entity.CREATE));
        assertEq(_calledOpType, Entity.CREATE);
    }

    function test_dispatch_routesUpdate() public {
        this.doDispatch(_op(Entity.UPDATE));
        assertEq(_calledOpType, Entity.UPDATE);
    }

    function test_dispatch_routesExtend() public {
        this.doDispatch(_op(Entity.EXTEND));
        assertEq(_calledOpType, Entity.EXTEND);
    }

    function test_dispatch_routesTransfer() public {
        this.doDispatch(_op(Entity.TRANSFER));
        assertEq(_calledOpType, Entity.TRANSFER);
    }

    function test_dispatch_routesDelete() public {
        this.doDispatch(_op(Entity.DELETE));
        assertEq(_calledOpType, Entity.DELETE);
    }

    function test_dispatch_routesExpire() public {
        this.doDispatch(_op(Entity.EXPIRE));
        assertEq(_calledOpType, Entity.EXPIRE);
    }

    // =========================================================================
    // Invalid op types
    // =========================================================================

    function test_dispatch_operationTypeZero_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Entity.InvalidOpType.selector, uint8(0)));
        this.doDispatch(_op(Entity.UNINITIALIZED));
    }

    function test_dispatch_operationTypeSeven_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Entity.InvalidOpType.selector, uint8(7)));
        this.doDispatch(_op(7));
    }

    function test_dispatch_operationType255_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(Entity.InvalidOpType.selector, uint8(255)));
        this.doDispatch(_op(255));
    }

    // =========================================================================
    // Return values are forwarded from handler
    // =========================================================================

    function test_dispatch_forwardsReturnValues() public {
        (bytes32 key, bytes32 hash) = this.doDispatch(_op(Entity.CREATE));
        assertEq(key, keccak256("key"));
        assertEq(hash, keccak256("hash"));
    }
}
