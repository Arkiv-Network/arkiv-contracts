// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {
    Ident32,
    Ident32Empty,
    Ident32TooLong,
    Ident32InvalidByte,
    IDENT_CHARSET,
    IDENT_LEADING,
    encodeIdent32,
    decodeIdent32,
    validateIdent32
} from "../../../src/types/Ident32.sol";

contract Ident32Test is Test {
    // -------------------------------------------------------------------------
    // Calldata wrapper
    // -------------------------------------------------------------------------

    function doValidate(Ident32 value) external pure returns (uint256) {
        return validateIdent32(value);
    }

    function doEncode(string calldata value) external pure returns (Ident32) {
        return encodeIdent32(value);
    }

    // =========================================================================
    // encodeIdent32 / decodeIdent32 — roundtrip
    // =========================================================================

    function test_encodeDecode_short() public pure {
        assertEq(decodeIdent32(encodeIdent32("count")), "count");
    }

    function test_encodeDecode_single() public pure {
        assertEq(decodeIdent32(encodeIdent32("x")), "x");
    }

    function test_encodeDecode_dotted() public pure {
        assertEq(decodeIdent32(encodeIdent32("content.length")), "content.length");
    }

    function test_encodeDecode_kebab() public pure {
        assertEq(decodeIdent32(encodeIdent32("x-custom")), "x-custom");
    }

    function test_encodeDecode_snake() public pure {
        assertEq(decodeIdent32(encodeIdent32("file_size")), "file_size");
    }

    function test_encodeDecode_digits() public pure {
        assertEq(decodeIdent32(encodeIdent32("v2")), "v2");
    }

    function test_encodeDecode_maxLength() public pure {
        // 32 chars: a + 31 lowercase chars
        string memory v = "abcdefghijklmnopqrstuvwxyz012345";
        assertEq(bytes(v).length, 32);
        assertEq(decodeIdent32(encodeIdent32(v)), v);
    }

    function test_encode_revertsEmpty() public {
        vm.expectRevert(Ident32Empty.selector);
        this.doEncode("");
    }

    function test_encode_revertsTooLong() public {
        vm.expectRevert(abi.encodeWithSelector(Ident32TooLong.selector, uint256(33)));
        this.doEncode("abcdefghijklmnopqrstuvwxyz0123456");
    }

    // =========================================================================
    // validateIdent32 — valid identifiers
    // =========================================================================

    function test_validate_simple() public view {
        assertEq(this.doValidate(encodeIdent32("count")), 5);
    }

    function test_validate_singleChar() public view {
        assertEq(this.doValidate(encodeIdent32("x")), 1);
    }

    function test_validate_withDigits() public view {
        assertEq(this.doValidate(encodeIdent32("tag2")), 4);
    }

    function test_validate_dotted() public view {
        assertEq(this.doValidate(encodeIdent32("content.length")), 14);
    }

    function test_validate_kebab() public view {
        assertEq(this.doValidate(encodeIdent32("x-custom")), 8);
    }

    function test_validate_snake() public view {
        assertEq(this.doValidate(encodeIdent32("file_size")), 9);
    }

    function test_validate_allSeparators() public view {
        assertEq(this.doValidate(encodeIdent32("a.b-c_d")), 7);
    }

    function test_validate_maxLength32() public view {
        Ident32 v = encodeIdent32("abcdefghijklmnopqrstuvwxyz012345");
        assertEq(this.doValidate(v), 32);
    }

    // =========================================================================
    // validateIdent32 — leading byte
    // =========================================================================

    function test_validate_rejectsLeadingDigit() public {
        Ident32 v = encodeIdent32("0count");
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(0), bytes1("0")));
        this.doValidate(v);
    }

    function test_validate_rejectsLeadingDot() public {
        Ident32 v = encodeIdent32(".hidden");
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(0), bytes1(".")));
        this.doValidate(v);
    }

    function test_validate_rejectsLeadingHyphen() public {
        Ident32 v = encodeIdent32("-flag");
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(0), bytes1("-")));
        this.doValidate(v);
    }

    function test_validate_rejectsLeadingUnderscore() public {
        Ident32 v = encodeIdent32("_private");
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(0), bytes1("_")));
        this.doValidate(v);
    }

    function test_validate_acceptsLeading_a() public view {
        assertEq(this.doValidate(encodeIdent32("a")), 1);
    }

    function test_validate_acceptsLeading_z() public view {
        assertEq(this.doValidate(encodeIdent32("z")), 1);
    }

    // =========================================================================
    // validateIdent32 — charset rejections
    // =========================================================================

    function test_validate_rejectsUppercase_A() public {
        Ident32 v = Ident32.wrap(bytes32(bytes1("A")));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(0), bytes1("A")));
        this.doValidate(v);
    }

    function test_validate_rejectsUppercase_Z() public {
        Ident32 v = Ident32.wrap(bytes32(bytes1("Z")));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(0), bytes1("Z")));
        this.doValidate(v);
    }

    function test_validate_rejectsUppercaseInMiddle() public {
        bytes32 raw = Ident32.unwrap(encodeIdent32("abcde"));
        // Clear the original 'c' at position 2 and set to 'X'
        raw = raw & ~(bytes32(bytes1(0xFF)) >> (2 * 8));
        raw = raw | (bytes32(bytes1("X")) >> (2 * 8));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(2), bytes1("X")));
        this.doValidate(Ident32.wrap(raw));
    }

    function test_validate_rejectsSpace() public {
        bytes32 raw = Ident32.unwrap(encodeIdent32("ab"));
        raw = raw | (bytes32(bytes1(" ")) >> (2 * 8));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(2), bytes1(" ")));
        this.doValidate(Ident32.wrap(raw));
    }

    function test_validate_rejectsControlChar() public {
        Ident32 v = Ident32.wrap(bytes32(bytes1(0x09))); // tab
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(0), bytes1(0x09)));
        this.doValidate(v);
    }

    function test_validate_rejectsDel() public {
        Ident32 v = Ident32.wrap(bytes32(bytes1(0x7F)));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(0), bytes1(0x7F)));
        this.doValidate(v);
    }

    function test_validate_rejectsHighByte() public {
        Ident32 v = Ident32.wrap(bytes32(bytes1(0x80)));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(0), bytes1(0x80)));
        this.doValidate(v);
    }

    function test_validate_rejectsSlash() public {
        bytes32 raw = Ident32.unwrap(encodeIdent32("ab"));
        raw = raw | (bytes32(bytes1("/")) >> (2 * 8));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(2), bytes1("/")));
        this.doValidate(Ident32.wrap(raw));
    }

    function test_validate_rejectsColon() public {
        bytes32 raw = Ident32.unwrap(encodeIdent32("ab"));
        raw = raw | (bytes32(bytes1(":")) >> (2 * 8));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(2), bytes1(":")));
        this.doValidate(Ident32.wrap(raw));
    }

    function test_validate_rejectsSemicolon() public {
        bytes32 raw = Ident32.unwrap(encodeIdent32("ab"));
        raw = raw | (bytes32(bytes1(";")) >> (2 * 8));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(2), bytes1(";")));
        this.doValidate(Ident32.wrap(raw));
    }

    function test_validate_rejectsEquals() public {
        bytes32 raw = Ident32.unwrap(encodeIdent32("ab"));
        raw = raw | (bytes32(bytes1("=")) >> (2 * 8));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(2), bytes1("=")));
        this.doValidate(Ident32.wrap(raw));
    }

    function test_validate_rejectsAt() public {
        bytes32 raw = Ident32.unwrap(encodeIdent32("ab"));
        raw = raw | (bytes32(bytes1("@")) >> (2 * 8));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(2), bytes1("@")));
        this.doValidate(Ident32.wrap(raw));
    }

    function test_validate_rejectsExclamation() public {
        bytes32 raw = Ident32.unwrap(encodeIdent32("ab"));
        raw = raw | (bytes32(bytes1("!")) >> (2 * 8));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(2), bytes1("!")));
        this.doValidate(Ident32.wrap(raw));
    }

    function test_validate_rejectsHash() public {
        bytes32 raw = Ident32.unwrap(encodeIdent32("ab"));
        raw = raw | (bytes32(bytes1("#")) >> (2 * 8));
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(2), bytes1("#")));
        this.doValidate(Ident32.wrap(raw));
    }

    // =========================================================================
    // validateIdent32 — empty and embedded nulls
    // =========================================================================

    function test_validate_rejectsEmpty() public {
        vm.expectRevert(Ident32Empty.selector);
        this.doValidate(Ident32.wrap(bytes32(0)));
    }

    function test_validate_rejectsEmbeddedNull() public {
        // "ab\0cd" — null at position 2, then non-zero at 3
        Ident32 v = Ident32.wrap(bytes32(bytes4(0x61620063))); // a b \0 c
        vm.expectRevert(abi.encodeWithSelector(Ident32InvalidByte.selector, uint256(3), bytes1("c")));
        this.doValidate(v);
    }

    // =========================================================================
    // IDENT_CHARSET bitmap — spot checks
    // =========================================================================

    function test_bitmap_lowercaseSet() public pure {
        for (uint8 c = 0x61; c <= 0x7A; c++) {
            assertTrue((IDENT_CHARSET >> c) & 1 == 1);
        }
    }

    function test_bitmap_digitsSet() public pure {
        for (uint8 c = 0x30; c <= 0x39; c++) {
            assertTrue((IDENT_CHARSET >> c) & 1 == 1);
        }
    }

    function test_bitmap_separatorsSet() public pure {
        assertTrue((IDENT_CHARSET >> 0x2D) & 1 == 1); // -
        assertTrue((IDENT_CHARSET >> 0x2E) & 1 == 1); // .
        assertTrue((IDENT_CHARSET >> 0x5F) & 1 == 1); // _
    }

    function test_bitmap_uppercaseUnset() public pure {
        for (uint8 c = 0x41; c <= 0x5A; c++) {
            assertTrue((IDENT_CHARSET >> c) & 1 == 0);
        }
    }

    function test_bitmap_spaceUnset() public pure {
        assertTrue((IDENT_CHARSET >> 0x20) & 1 == 0);
    }

    function test_bitmap_slashUnset() public pure {
        assertTrue((IDENT_CHARSET >> 0x2F) & 1 == 0);
    }

    function test_bitmap_colonUnset() public pure {
        assertTrue((IDENT_CHARSET >> 0x3A) & 1 == 0);
    }

    function test_bitmap_leadingOnlyLowercase() public pure {
        // a-z set
        for (uint8 c = 0x61; c <= 0x7A; c++) {
            assertTrue((IDENT_LEADING >> c) & 1 == 1);
        }
        // digits unset
        for (uint8 c = 0x30; c <= 0x39; c++) {
            assertTrue((IDENT_LEADING >> c) & 1 == 0);
        }
        // separators unset
        assertTrue((IDENT_LEADING >> 0x2D) & 1 == 0);
        assertTrue((IDENT_LEADING >> 0x2E) & 1 == 0);
        assertTrue((IDENT_LEADING >> 0x5F) & 1 == 0);
    }
}
