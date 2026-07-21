// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EntityV2} from "./EntityV2.sol";

/// @title ProtocolParams
/// @dev Reference analog of the §3 params registry (engine-facing view):
/// height-selectable consensus limits, engine cost values (the §10
/// meter's price source, mirroring native `write_costs`), and immutable
/// chain-config constants (domain — the key-derivation separator,
/// statically declared like everything else in chain config). The execution client
/// probes all three once per batch — the closest contract analog of
/// binding `params_at(height)` once per block.
///
/// The engine meter charges these cost values against env.budget; EVM
/// gas is metered independently and differs — differential tests may
/// compare engine cost, but never gas.
contract ProtocolParams {
    uint256 public immutable MAX_ATTRIBUTES;
    uint256 public immutable MAX_MUTATIONS;
    uint256 public immutable MAX_STRING_BYTES;
    uint256 public immutable MAX_PAYLOAD_BYTES;
    uint64 public immutable EXECUTE_BASE_COST;
    uint64 public immutable RECORD_READ_COST;
    uint64 public immutable RECORD_WRITE_COST;
    uint64 public immutable VALUE_BYTE_COST;
    bytes32 public immutable DOMAIN;

    constructor(EntityV2.Limits memory limits_, EntityV2.Costs memory costs_, EntityV2.Constants memory constants_) {
        MAX_ATTRIBUTES = limits_.maxAttributes;
        MAX_MUTATIONS = limits_.maxMutations;
        MAX_STRING_BYTES = limits_.maxStringBytes;
        MAX_PAYLOAD_BYTES = limits_.maxPayloadBytes;
        EXECUTE_BASE_COST = costs_.executeBase;
        RECORD_READ_COST = costs_.recordRead;
        RECORD_WRITE_COST = costs_.recordWrite;
        VALUE_BYTE_COST = costs_.valueByte;
        DOMAIN = constants_.domain;
    }

    function limits() external view returns (EntityV2.Limits memory) {
        return EntityV2.Limits({
            maxAttributes: MAX_ATTRIBUTES,
            maxMutations: MAX_MUTATIONS,
            maxStringBytes: MAX_STRING_BYTES,
            maxPayloadBytes: MAX_PAYLOAD_BYTES
        });
    }

    function costs() external view returns (EntityV2.Costs memory) {
        return EntityV2.Costs({
            executeBase: EXECUTE_BASE_COST,
            recordRead: RECORD_READ_COST,
            recordWrite: RECORD_WRITE_COST,
            valueByte: VALUE_BYTE_COST
        });
    }

    function constants() external view returns (EntityV2.Constants memory) {
        return EntityV2.Constants({domain: DOMAIN});
    }
}
