// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Ident32, encodeIdent32} from "../../contracts/types/Ident32.sol";
import {RecordReader} from "../../contracts/RecordReader.sol";
import {RecordStore} from "../../contracts/RecordStore.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Unit tests for the generic record/cell store, independent of
/// any entity semantics: the test contract deploys the store and is
/// therefore its ENGINE.
contract RecordStoreTest is Test {
    RecordStore store;

    bytes32 KEY = keccak256("record");
    Ident32 ALPHA = encodeIdent32("alpha");
    Ident32 BETA = encodeIdent32("beta");
    Ident32 GAMMA = encodeIdent32("gamma");
    Ident32 SYS = Ident32.wrap("$sys");

    function setUp() public {
        store = new RecordStore();
        store.createRecord(KEY, 7);
    }

    function put(Ident32 name, bytes memory value) internal {
        store.putCell(KEY, RecordReader.Cell({name: name, typeId: 1, value: value}));
    }

    function assertNames(Ident32[] memory expected) internal view {
        Ident32[] memory names = store.cellNames(KEY);
        assertEq(names.length, expected.length + 1);
        assertEq(Ident32.unwrap(names[0]), store.KEY_CELL_NAME());
        for (uint256 i = 0; i < expected.length; i++) {
            assertEq(Ident32.unwrap(names[i + 1]), Ident32.unwrap(expected[i]));
        }
    }

    // -------------------------------------------------------------------------
    // records
    // -------------------------------------------------------------------------

    function test_createRecord_writesKeyCell() public view {
        assertTrue(store.hasRecord(KEY));
        assertEq(store.recordType(KEY), 7);
        RecordReader.Cell memory keyCell = store.getCell(KEY, Ident32.wrap(store.KEY_CELL_NAME()));
        assertEq(Ident32.unwrap(keyCell.name), store.KEY_CELL_NAME());
        assertEq(keyCell.typeId, 7);
        assertEq(abi.decode(keyCell.value, (bytes32)), KEY);
    }

    function test_createRecord_existing_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(RecordStore.RecordAlreadyExists.selector, KEY));
        store.createRecord(KEY, 1);
    }

    function test_hasRecord_falseForUnknown() public view {
        assertFalse(store.hasRecord(keccak256("other")));
        assertEq(store.recordType(keccak256("other")), 0);
    }

    function test_deleteRecord_clearsEverything() public {
        put(ALPHA, "a");
        put(BETA, "b");
        store.deleteRecord(KEY);

        assertFalse(store.hasRecord(KEY));
        assertEq(store.cellNames(KEY).length, 0);
        assertEq(Ident32.unwrap(store.getCell(KEY, ALPHA).name), 0);
        assertEq(Ident32.unwrap(store.getCell(KEY, Ident32.wrap(store.KEY_CELL_NAME())).name), 0);
    }

    function test_deleteRecord_unknown_reverts() public {
        bytes32 other = keccak256("other");
        vm.expectRevert(abi.encodeWithSelector(RecordReader.RecordNotFound.selector, other));
        store.deleteRecord(other);
    }

    // -------------------------------------------------------------------------
    // cells
    // -------------------------------------------------------------------------

    function test_putCell_insertsSorted() public {
        // Insert out of order: gamma, alpha, $sys, beta.
        put(GAMMA, "g");
        put(ALPHA, "a");
        put(SYS, "s");
        put(BETA, "b");

        Ident32[] memory expected = new Ident32[](4);
        expected[0] = SYS; // '$' sorts before a-z, after '#key'
        expected[1] = ALPHA;
        expected[2] = BETA;
        expected[3] = GAMMA;
        assertNames(expected);
    }

    function test_putCell_overwrite_keepsOrderAndCells() public {
        put(ALPHA, "a");
        put(BETA, "b");
        store.putCell(KEY, RecordReader.Cell({name: ALPHA, typeId: 3, value: "aa"}));

        Ident32[] memory expected = new Ident32[](2);
        expected[0] = ALPHA;
        expected[1] = BETA;
        assertNames(expected);

        RecordReader.Cell memory f = store.getCell(KEY, ALPHA);
        assertEq(f.typeId, 3);
        assertEq(f.value, "aa");
    }

    function test_putCell_reservedName_reverts() public {
        Ident32 keyName = Ident32.wrap(store.KEY_CELL_NAME());
        vm.expectRevert(abi.encodeWithSelector(RecordStore.ReservedCellName.selector, KEY, keyName));
        put(keyName, "x");

        // The empty name and names sorting before '#key' are equally reserved.
        vm.expectRevert(abi.encodeWithSelector(RecordStore.ReservedCellName.selector, KEY, Ident32.wrap(0)));
        put(Ident32.wrap(0), "x");
        vm.expectRevert(abi.encodeWithSelector(RecordStore.ReservedCellName.selector, KEY, Ident32.wrap("!a")));
        put(Ident32.wrap("!a"), "x");
    }

    function test_putCell_unknownRecord_reverts() public {
        bytes32 other = keccak256("other");
        vm.expectRevert(abi.encodeWithSelector(RecordReader.RecordNotFound.selector, other));
        store.putCell(other, RecordReader.Cell({name: ALPHA, typeId: 1, value: "a"}));
    }

    function test_removeCell_shiftsSorted() public {
        put(ALPHA, "a");
        put(BETA, "b");
        put(GAMMA, "g");
        store.removeCell(KEY, BETA);

        Ident32[] memory expected = new Ident32[](2);
        expected[0] = ALPHA;
        expected[1] = GAMMA;
        assertNames(expected);
        assertEq(Ident32.unwrap(store.getCell(KEY, BETA).name), 0);

        // Re-inserting lands back in sorted position.
        put(BETA, "b2");
        expected = new Ident32[](3);
        expected[0] = ALPHA;
        expected[1] = BETA;
        expected[2] = GAMMA;
        assertNames(expected);
    }

    function test_removeCell_absent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(RecordStore.CellNotFound.selector, KEY, ALPHA));
        store.removeCell(KEY, ALPHA);
    }

    function test_removeCell_keyCell_reverts() public {
        Ident32 keyName = Ident32.wrap(store.KEY_CELL_NAME());
        vm.expectRevert(abi.encodeWithSelector(RecordStore.ReservedCellName.selector, KEY, keyName));
        store.removeCell(KEY, keyName);
    }

    // -------------------------------------------------------------------------
    // reads
    // -------------------------------------------------------------------------

    function test_readRecord_returnsAllCellsSorted() public {
        put(BETA, "b");
        put(ALPHA, "a");

        RecordReader.Cell[] memory cells = store.readRecord(KEY);
        assertEq(cells.length, 3);
        assertEq(Ident32.unwrap(cells[0].name), store.KEY_CELL_NAME());
        assertEq(Ident32.unwrap(cells[1].name), Ident32.unwrap(ALPHA));
        assertEq(cells[1].value, "a");
        assertEq(Ident32.unwrap(cells[2].name), Ident32.unwrap(BETA));
        assertEq(cells[2].value, "b");
    }

    function test_readRecord_unknown_reverts() public {
        bytes32 other = keccak256("other");
        vm.expectRevert(abi.encodeWithSelector(RecordReader.RecordNotFound.selector, other));
        store.readRecord(other);
    }

    function test_getCell_absent_softReturns() public view {
        RecordReader.Cell memory f = store.getCell(KEY, ALPHA);
        assertEq(Ident32.unwrap(f.name), 0);
        assertEq(f.typeId, 0);
        assertEq(f.value.length, 0);
    }

    // -------------------------------------------------------------------------
    // access control
    // -------------------------------------------------------------------------

    function test_mutators_onlyEngine() public {
        address rando = makeAddr("rando");
        bytes memory err = abi.encodeWithSelector(RecordStore.OnlyEngine.selector, rando);

        vm.startPrank(rando);
        vm.expectRevert(err);
        store.createRecord(keccak256("other"), 1);
        vm.expectRevert(err);
        store.putCell(KEY, RecordReader.Cell({name: ALPHA, typeId: 1, value: "a"}));
        vm.expectRevert(err);
        store.removeCell(KEY, ALPHA);
        vm.expectRevert(err);
        store.deleteRecord(KEY);
        vm.stopPrank();
    }
}
