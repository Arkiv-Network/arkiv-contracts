// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ident32} from "./types/Ident32.sol";

/// @title RecordReader
/// @dev Read side of the generic record/cell store (the §6 storage interface):
/// holds the record state and every view over it, but no mutators —
/// those are added by RecordStore. Useful on its own wherever read-only
/// access to records is the appropriate capability.
///
/// A record is a set of named, typed cells, enumerable in ascending
/// name order. The single structural anchor: every record has exactly
/// one key cell, which is always its first cell — the key cell's
/// reserved name '#key' (0x23) sorts before every permitted cell name,
/// so ordinary sorting keeps it in front. A record exists iff its key
/// cell does. typeId and value are opaque here; interpretation is the
/// business logic's.
abstract contract RecordReader {
    /// @dev Reverted when an op targets a nonexistent record.
    error RecordNotFound(bytes32 key);

    /// @dev A named, typed value — one cell of a record.
    struct Cell {
        Ident32 name;
        uint8 typeId;
        bytes value;
    }

    /// @dev Reserved name of the key cell. All other cell names must
    /// sort strictly after it.
    bytes32 public constant KEY_CELL_NAME = "#key";

    // -------------------------------------------------------------------------
    // Records
    // -------------------------------------------------------------------------

    mapping(bytes32 key => mapping(Ident32 name => Cell)) internal _cells;
    mapping(bytes32 key => Ident32[] names) internal _cellNames;

    // -------------------------------------------------------------------------
    // Reads
    // -------------------------------------------------------------------------

    function hasRecord(bytes32 key) external view returns (bool) {
        return _hasRecord(key);
    }

    /// @notice All cells of a record, sorted ascending by name — the
    /// key cell first.
    function readRecord(bytes32 key) external view returns (Cell[] memory cells) {
        if (!_hasRecord(key)) revert RecordNotFound(key);
        Ident32[] storage names = _cellNames[key];
        cells = new Cell[](names.length);
        for (uint256 i = 0; i < names.length; i++) {
            cells[i] = _cells[key][names[i]];
        }
    }

    /// @notice A single cell. Absent cells return an empty Cell
    /// (name == 0) rather than reverting, so reads double as probes.
    function getCell(bytes32 key, Ident32 name) external view returns (Cell memory) {
        return _cells[key][name];
    }

    /// @notice All cell names of a record, sorted ascending — the key
    /// cell first.
    function cellNames(bytes32 key) external view returns (Ident32[] memory) {
        return _cellNames[key];
    }

    /// @notice The record's type tag, carried in the key cell's typeId
    /// slot. Opaque to the store — the business logic assigns and
    /// interprets it. 0 for untyped and for nonexistent records
    /// (disambiguate with hasRecord).
    function recordType(bytes32 key) external view returns (uint8) {
        return _cells[key][Ident32.wrap(KEY_CELL_NAME)].typeId;
    }

    /// @dev A record exists iff its key cell does.
    function _hasRecord(bytes32 key) internal view returns (bool) {
        return Ident32.unwrap(_cells[key][Ident32.wrap(KEY_CELL_NAME)].name) != 0;
    }
}
