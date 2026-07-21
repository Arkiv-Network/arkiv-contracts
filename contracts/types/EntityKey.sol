// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev Globally unique entity identifier. Wraps bytes32 for compile-time
/// type safety. Derived from (chainId, registry, owner, nonce) — see
/// EntityV2.entityKey().
type EntityKey is bytes32;

using {entityKeyEq as ==, entityKeyNeq as !=} for EntityKey global;

function entityKeyEq(EntityKey a, EntityKey b) pure returns (bool) {
    return EntityKey.unwrap(a) == EntityKey.unwrap(b);
}

function entityKeyNeq(EntityKey a, EntityKey b) pure returns (bool) {
    return EntityKey.unwrap(a) != EntityKey.unwrap(b);
}
