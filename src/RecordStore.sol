// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ident32} from "./types/Ident32.sol";
import {RecordReader} from "./RecordReader.sol";

/// @title RecordStore
/// @dev Reference analog of the §5 storage interface: RecordReader plus the
/// state-changing operations, restricted to the engine. The store knows
/// nothing about the data model on top of it and can back entities,
/// documents, queues, or counters unchanged.
///
/// Structural invariants enforced here — and nothing more:
///   - every record has exactly one key cell, always first; the engine
///     supplies record keys (derivation is business logic; the store
///     only guards against collisions)
///   - cell names are unique per record and sort strictly after the
///     reserved key cell name
///   - cell enumeration is sorted strictly ascending by name
/// Everything else — name grammar and namespaces, cell caps, typeId
/// and value interpretation, authorization — is business logic. The
/// store is configured at deployment, outside the engine.
contract RecordStore is RecordReader {
    /// @dev Reverted when anyone but the engine calls a mutator.
    error OnlyEngine(address caller);
    /// @dev Reverted when createRecord targets an existing key.
    error RecordAlreadyExists(bytes32 key);
    /// @dev Reverted when removeCell targets an absent cell.
    error CellNotFound(bytes32 key, Ident32 name);
    /// @dev Reverted when a cell name does not sort strictly after the
    /// reserved key cell name (covers the empty name).
    error ReservedCellName(bytes32 key, Ident32 name);

    address public immutable ENGINE;

    modifier onlyEngine() {
        if (msg.sender != ENGINE) revert OnlyEngine(msg.sender);
        _;
    }

    constructor() {
        ENGINE = msg.sender;
    }

    // -------------------------------------------------------------------------
    // Writes — engine only
    // -------------------------------------------------------------------------

    /// @dev Create a record under an engine-supplied key: writes the
    /// key cell, whose presence marks existence. The record type rides
    /// in the key cell's typeId slot — an opaque tag the business logic
    /// assigns (0 = undefined).
    function createRecord(bytes32 key, uint8 recordType) external onlyEngine {
        if (_hasRecord(key)) revert RecordAlreadyExists(key);
        Ident32 keyCell = Ident32.wrap(KEY_CELL_NAME);
        _cells[key][keyCell] = Cell({name: keyCell, typeId: recordType, value: abi.encode(key)});
        _cellNames[key].push(keyCell);
    }

    /// @dev Insert or overwrite a cell. Inserts keep the name list
    /// sorted; names must sort strictly after the key cell name.
    function putCell(bytes32 key, Cell calldata cell) external onlyEngine {
        if (!_hasRecord(key)) revert RecordNotFound(key);
        if (Ident32.unwrap(cell.name) <= KEY_CELL_NAME) revert ReservedCellName(key, cell.name);
        if (Ident32.unwrap(_cells[key][cell.name].name) == 0) {
            _insertSorted(_cellNames[key], cell.name);
        }
        _cells[key][cell.name] = cell;
    }

    function removeCell(bytes32 key, Ident32 name) external onlyEngine {
        if (!_hasRecord(key)) revert RecordNotFound(key);
        if (Ident32.unwrap(name) <= KEY_CELL_NAME) revert ReservedCellName(key, name);
        if (Ident32.unwrap(_cells[key][name].name) == 0) revert CellNotFound(key, name);
        delete _cells[key][name];
        _removeSorted(_cellNames[key], name);
    }

    /// @dev Delete a record and all of its cells, the key cell
    /// included.
    function deleteRecord(bytes32 key) external onlyEngine {
        if (!_hasRecord(key)) revert RecordNotFound(key);
        Ident32[] storage names = _cellNames[key];
        for (uint256 i = 0; i < names.length; i++) {
            delete _cells[key][names[i]];
        }
        delete _cellNames[key];
    }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    /// @dev Insert a name into the sorted list, shifting larger names right.
    /// The caller guarantees the name is not already present.
    function _insertSorted(Ident32[] storage names, Ident32 name) internal {
        uint256 i = names.length;
        names.push(name);
        while (i > 0 && names[i - 1] > name) {
            names[i] = names[i - 1];
            i--;
        }
        names[i] = name;
    }

    /// @dev Remove a name from the sorted list, shifting larger names left.
    /// The caller guarantees the name is present.
    function _removeSorted(Ident32[] storage names, Ident32 name) internal {
        uint256 last = names.length - 1;
        uint256 i;
        while (names[i] != name) {
            i++;
        }
        for (; i < last; i++) {
            names[i] = names[i + 1];
        }
        names.pop();
    }
}
