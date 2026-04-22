// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {
    Mime128,
    MimeEmpty,
    MimeTooLong,
    MimeInvalidByte,
    MimeIncomplete,
    encodeMime128,
    decodeMime128,
    validateMime128,
    mime128Hash,
    mime128HashM,
    MIME_TOKEN,
    LOWER_PRINTABLE_ASCII
} from "../../../contracts/types/Mime128.sol";

contract Mime128Test is Test {
    // -------------------------------------------------------------------------
    // Calldata wrapper — validateMime128 takes calldata, tests use memory.
    // -------------------------------------------------------------------------

    function doValidate(Mime128 calldata m) external pure returns (uint256) {
        return validateMime128(m);
    }

    function doHash(Mime128 calldata m) external pure returns (bytes32) {
        return mime128Hash(m);
    }

    // =========================================================================
    // encodeMime128 / decodeMime128 — roundtrip
    // =========================================================================

    function test_encodeDecode_bare() public pure {
        assertEq(decodeMime128(encodeMime128("text/plain")), "text/plain");
    }

    function test_encodeDecode_withParams() public pure {
        string memory v = "text/plain; charset=utf-8";
        assertEq(decodeMime128(encodeMime128(v)), v);
    }

    function test_encodeDecode_multipleParams() public pure {
        string memory v = "text/plain; charset=utf-8; boundary=something";
        assertEq(decodeMime128(encodeMime128(v)), v);
    }

    function test_encodeDecode_vendorType() public pure {
        string memory v = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet";
        assertEq(decodeMime128(encodeMime128(v)), v);
    }

    function test_encodeDecode_maxLength() public pure {
        // 128 'a' characters — fills all 4 words.
        bytes memory b = new bytes(128);
        for (uint256 i = 0; i < 128; i++) {
            b[i] = "a";
        }
        string memory v = string(b);
        assertEq(decodeMime128(encodeMime128(v)), v);
    }

    function test_encodeDecode_singleChar() public pure {
        assertEq(decodeMime128(encodeMime128("a")), "a");
    }

    function test_encodeDecode_exactly32bytes() public pure {
        // Crosses first word boundary exactly.
        string memory v = "application/octet-stream+extn";
        assertEq(bytes(v).length <= 32, true);
        assertEq(decodeMime128(encodeMime128(v)), v);
    }

    function test_encodeDecode_33bytes() public pure {
        // Crosses into second word.
        bytes memory b = new bytes(33);
        for (uint256 i = 0; i < 33; i++) {
            b[i] = "x";
        }
        string memory v = string(b);
        assertEq(decodeMime128(encodeMime128(v)), v);
    }

    function doEncode(string calldata v) external pure returns (Mime128 memory) {
        return encodeMime128(v);
    }

    function test_encode_revertsEmpty() public {
        vm.expectRevert(MimeEmpty.selector);
        this.doEncode("");
    }

    function test_encode_revertsTooLong() public {
        bytes memory b = new bytes(129);
        for (uint256 i = 0; i < 129; i++) {
            b[i] = "a";
        }
        vm.expectRevert(abi.encodeWithSelector(MimeTooLong.selector, uint256(129), uint256(128)));
        this.doEncode(string(b));
    }

    // =========================================================================
    // validateMime128 — valid MIME types
    // =========================================================================

    function test_validate_bare_textPlain() public view {
        Mime128 memory m = encodeMime128("text/plain");
        assertEq(this.doValidate(m), 10);
    }

    function test_validate_bare_applicationJson() public view {
        Mime128 memory m = encodeMime128("application/json");
        assertEq(this.doValidate(m), 16);
    }

    function test_validate_bare_applicationOctetStream() public view {
        Mime128 memory m = encodeMime128("application/octet-stream");
        assertEq(this.doValidate(m), 24);
    }

    function test_validate_bare_imageWebp() public view {
        Mime128 memory m = encodeMime128("image/webp");
        assertEq(this.doValidate(m), 10);
    }

    function test_validate_bare_xToken() public view {
        // x- prefix vendor types
        Mime128 memory m = encodeMime128("application/x-tar");
        assertEq(this.doValidate(m), 17);
    }

    function test_validate_bare_vndType() public view {
        Mime128 memory m = encodeMime128("application/vnd.ms-excel");
        assertEq(this.doValidate(m), 24);
    }

    function test_validate_withParam_charset() public view {
        Mime128 memory m = encodeMime128("text/plain; charset=utf-8");
        assertEq(this.doValidate(m), 25);
    }

    function test_validate_withParam_noSpace() public view {
        // No space after semicolon — OWS is optional.
        Mime128 memory m = encodeMime128("text/plain;charset=utf-8");
        assertEq(this.doValidate(m), 24);
    }

    function test_validate_withParam_multipleSpaces() public view {
        // Multiple spaces after semicolon.
        Mime128 memory m = encodeMime128("text/plain;   charset=utf-8");
        assertEq(this.doValidate(m), 27);
    }

    function test_validate_multipleParams() public view {
        Mime128 memory m = encodeMime128("text/plain; a=b; c=d");
        assertEq(this.doValidate(m), 20);
    }

    function test_validate_multipleParams_noSpaces() public view {
        Mime128 memory m = encodeMime128("text/plain;a=b;c=d");
        assertEq(this.doValidate(m), 18);
    }

    function test_validate_longVendorWithParam() public view {
        string memory v = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet; charset=utf-8";
        Mime128 memory m = encodeMime128(v);
        assertEq(this.doValidate(m), bytes(v).length);
    }

    function test_validate_fullLength128() public view {
        // Build a valid 128-byte MIME type: a/b;c=<pad to 128>
        bytes memory b = new bytes(128);
        b[0] = "a";
        b[1] = "/";
        b[2] = "b";
        b[3] = ";";
        b[4] = "c";
        b[5] = "=";
        for (uint256 i = 6; i < 128; i++) {
            b[i] = "d";
        }
        Mime128 memory m = encodeMime128(string(b));
        assertEq(this.doValidate(m), 128);
    }

    // =========================================================================
    // validateMime128 — token charset (all valid token chars accepted)
    // =========================================================================

    function test_validate_tokenChars_lowercase() public view {
        Mime128 memory m = encodeMime128("abcdefghijklmnopqrstuvwxyz/z");
        assertEq(this.doValidate(m), 28);
    }

    function test_validate_tokenChars_digits() public view {
        Mime128 memory m = encodeMime128("x0123456789/y");
        assertEq(this.doValidate(m), 13);
    }

    function test_validate_tokenChars_special() public view {
        // All non-alphanumeric token chars: ! # $ % & ' * + - . ^ _ ` { | } ~
        Mime128 memory m = encodeMime128("a!#$%&'*+-.^_`{|}~/b");
        assertEq(this.doValidate(m), 20);
    }

    // =========================================================================
    // validateMime128 — structural rejections
    // =========================================================================

    function test_validate_rejectsEmpty() public {
        Mime128 memory m;
        vm.expectRevert(MimeEmpty.selector);
        this.doValidate(m);
    }

    function test_validate_rejectsNoSlash() public {
        // "textplain" — no slash, ends in TYPE state.
        Mime128 memory m = encodeMime128("textplain");
        vm.expectRevert(MimeIncomplete.selector);
        this.doValidate(m);
    }

    function test_validate_rejectsEmptyType() public {
        // "/plain" — slash at position 0, empty type.
        Mime128 memory m = encodeMime128("/plain");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(0), bytes1("/")));
        this.doValidate(m);
    }

    function test_validate_rejectsEmptySubtype() public {
        // "text/" — slash at end, empty subtype.
        Mime128 memory m = encodeMime128("text/");
        vm.expectRevert(MimeIncomplete.selector);
        this.doValidate(m);
    }

    function test_validate_rejectsDanglingSemicolon() public {
        // "text/plain;" — semicolon with no parameter.
        Mime128 memory m = encodeMime128("text/plain;");
        vm.expectRevert(MimeIncomplete.selector);
        this.doValidate(m);
    }

    function test_validate_rejectsDanglingSemicolonWithSpace() public {
        // "text/plain; " — semicolon + space but no param name.
        Mime128 memory m = encodeMime128("text/plain; ");
        vm.expectRevert(MimeIncomplete.selector);
        this.doValidate(m);
    }

    function test_validate_rejectsEmptyParamName() public {
        // "text/plain; =value" — equals with no param name.
        Mime128 memory m = encodeMime128("text/plain; =value");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(12), bytes1("=")));
        this.doValidate(m);
    }

    function test_validate_rejectsEmptyParamValue() public {
        // "text/plain; charset=" — equals with no value.
        Mime128 memory m = encodeMime128("text/plain; charset=");
        vm.expectRevert(MimeIncomplete.selector);
        this.doValidate(m);
    }

    function test_validate_rejectsDoubleSlash() public {
        // "text//plain" — slash in subtype position.
        Mime128 memory m = encodeMime128("text//plain");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(5), bytes1("/")));
        this.doValidate(m);
    }

    function test_validate_rejectsSlashInParamValue() public {
        // "/" is a tspecial, not valid in token positions.
        Mime128 memory m = encodeMime128("text/plain; a=/b");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(14), bytes1("/")));
        this.doValidate(m);
    }

    function test_validate_rejectsSemicolonInType() public {
        // "text;plain" — semicolon before slash.
        Mime128 memory m = encodeMime128("text;plain");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(4), bytes1(";")));
        this.doValidate(m);
    }

    function test_validate_rejectsEqualsInType() public {
        // "te=xt/plain"
        Mime128 memory m = encodeMime128("te=xt/plain");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(2), bytes1("=")));
        this.doValidate(m);
    }

    function test_validate_rejectsSpaceInType() public {
        // "te xt/plain"
        Mime128 memory m = encodeMime128("te xt/plain");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(2), bytes1(" ")));
        this.doValidate(m);
    }

    function test_validate_rejectsSpaceInSubtype() public {
        // "text/pla in"
        Mime128 memory m = encodeMime128("text/pla in");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(8), bytes1(" ")));
        this.doValidate(m);
    }

    function test_validate_rejectsEmptySecondParamValue() public {
        // "text/plain; a=b; c="
        Mime128 memory m = encodeMime128("text/plain; a=b; c=");
        vm.expectRevert(MimeIncomplete.selector);
        this.doValidate(m);
    }

    // =========================================================================
    // validateMime128 — charset rejections
    // =========================================================================

    function test_validate_rejectsUppercaseType() public {
        Mime128 memory m = encodeMime128("Text/plain");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(0), bytes1("T")));
        this.doValidate(m);
    }

    function test_validate_rejectsUppercaseSubtype() public {
        Mime128 memory m = encodeMime128("text/Plain");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(5), bytes1("P")));
        this.doValidate(m);
    }

    function test_validate_rejectsUppercaseParamName() public {
        Mime128 memory m = encodeMime128("text/plain; Charset=utf-8");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(12), bytes1("C")));
        this.doValidate(m);
    }

    function test_validate_rejectsUppercaseParamValue() public {
        Mime128 memory m = encodeMime128("text/plain; charset=UTF-8");
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(20), bytes1("U")));
        this.doValidate(m);
    }

    function test_validate_rejectsControlChar() public {
        Mime128 memory m;
        m.data[0] = bytes32(bytes1(0x09)); // tab
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(0), bytes1(0x09)));
        this.doValidate(m);
    }

    function test_validate_rejectsDel() public {
        Mime128 memory m;
        m.data[0] = bytes32(bytes1(0x7F));
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(0), bytes1(0x7F)));
        this.doValidate(m);
    }

    function test_validate_rejectsHighByte() public {
        Mime128 memory m;
        m.data[0] = bytes32(bytes1(0x80));
        vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(0), bytes1(0x80)));
        this.doValidate(m);
    }

    function test_validate_rejectsNullByte() public {
        Mime128 memory m;
        m.data[0] = bytes32(bytes2(0x6100)); // "a\0" — no slash
        vm.expectRevert(MimeIncomplete.selector);
        this.doValidate(m);
    }

    // =========================================================================
    // validateMime128 — tspecials rejected in token positions
    // =========================================================================

    function test_validate_rejectsTspecials_inType() public {
        bytes1[15] memory tspecials = [
            bytes1('"'),
            bytes1("("),
            bytes1(")"),
            bytes1(","),
            bytes1("/"),
            bytes1(":"),
            bytes1(";"),
            bytes1("<"),
            bytes1("="),
            bytes1(">"),
            bytes1("?"),
            bytes1("@"),
            bytes1("["),
            bytes1("\\"),
            bytes1("]")
        ];

        for (uint256 k = 0; k < tspecials.length; k++) {
            Mime128 memory m;
            // Place tspecial as first byte of type.
            m.data[0] = bytes32(tspecials[k]);
            vm.expectRevert(abi.encodeWithSelector(MimeInvalidByte.selector, uint256(0), tspecials[k]));
            this.doValidate(m);
        }
    }

    // =========================================================================
    // validateMime128 — word boundary crossing
    // =========================================================================

    function test_validate_slashAtByte31() public view {
        // Type fills bytes 0–30, slash at byte 31, subtype in word 1.
        bytes memory b = new bytes(34);
        for (uint256 i = 0; i < 31; i++) {
            b[i] = "a";
        }
        b[31] = "/";
        b[32] = "b";
        b[33] = "b";
        Mime128 memory m = encodeMime128(string(b));
        assertEq(this.doValidate(m), 34);
    }

    function test_validate_slashAtByte32() public view {
        // Type fills bytes 0–31 (full first word), slash at byte 32 (first byte of word 1).
        bytes memory b = new bytes(35);
        for (uint256 i = 0; i < 32; i++) {
            b[i] = "a";
        }
        b[32] = "/";
        b[33] = "b";
        b[34] = "b";
        Mime128 memory m = encodeMime128(string(b));
        assertEq(this.doValidate(m), 35);
    }

    function test_validate_paramCrossesWordBoundary() public view {
        // Subtype ends at byte 30, semicolon at 31, param in word 1.
        bytes memory b = new bytes(40);
        b[0] = "a";
        b[1] = "/";
        for (uint256 i = 2; i < 31; i++) {
            b[i] = "b";
        }
        b[31] = ";";
        b[32] = "c";
        b[33] = "=";
        for (uint256 i = 34; i < 40; i++) {
            b[i] = "d";
        }
        Mime128 memory m = encodeMime128(string(b));
        assertEq(this.doValidate(m), 40);
    }

    // =========================================================================
    // MIME_TOKEN bitmap — spot checks
    // =========================================================================

    function test_bitmap_lowercaseSet() public pure {
        for (uint8 c = 0x61; c <= 0x7A; c++) {
            assertTrue((MIME_TOKEN >> c) & 1 == 1, string(abi.encodePacked("missing: ", bytes1(c))));
        }
    }

    function test_bitmap_digitsSet() public pure {
        for (uint8 c = 0x30; c <= 0x39; c++) {
            assertTrue((MIME_TOKEN >> c) & 1 == 1, string(abi.encodePacked("missing: ", bytes1(c))));
        }
    }

    function test_bitmap_uppercaseUnset() public pure {
        for (uint8 c = 0x41; c <= 0x5A; c++) {
            assertTrue((MIME_TOKEN >> c) & 1 == 0, string(abi.encodePacked("set: ", bytes1(c))));
        }
    }

    function test_bitmap_tspecialsUnset() public pure {
        bytes memory ts = '"(),/:;<=>?@[\\]';
        for (uint256 i = 0; i < ts.length; i++) {
            uint8 c = uint8(ts[i]);
            assertTrue((MIME_TOKEN >> c) & 1 == 0, string(abi.encodePacked("set: ", ts[i])));
        }
    }

    function test_bitmap_spaceUnset() public pure {
        assertTrue((MIME_TOKEN >> 0x20) & 1 == 0);
    }

    function test_bitmap_specialTokenCharsSet() public pure {
        bytes memory valid = "!#$%&'*+-.^_`{|}~";
        for (uint256 i = 0; i < valid.length; i++) {
            uint8 c = uint8(valid[i]);
            assertTrue((MIME_TOKEN >> c) & 1 == 1, string(abi.encodePacked("missing: ", valid[i])));
        }
    }

    // =========================================================================
    // mime128Hash — determinism and distinctness
    // =========================================================================

    function test_hash_deterministic() public view {
        Mime128 memory a = encodeMime128("application/json");
        Mime128 memory b = encodeMime128("application/json");
        assertEq(this.doHash(a), this.doHash(b));
    }

    function test_hash_distinct() public view {
        Mime128 memory a = encodeMime128("application/json");
        Mime128 memory b = encodeMime128("text/plain");
        assertTrue(this.doHash(a) != this.doHash(b));
    }

    function test_hash_memoryMatchesCalldata() public view {
        Mime128 memory m = encodeMime128("application/json");
        assertEq(this.doHash(m), mime128HashM(m));
    }

    function test_hash_matchesManualComputation() public pure {
        Mime128 memory m = encodeMime128("text/plain");
        bytes32 expected = keccak256(abi.encode(m.data[0], m.data[1], m.data[2], m.data[3]));
        assertEq(mime128HashM(m), expected);
    }

    function test_hash_paramOrderMatters() public view {
        // "text/plain; a=b; c=d" vs "text/plain; c=d; a=b" — different hashes.
        Mime128 memory a = encodeMime128("text/plain; a=b; c=d");
        Mime128 memory b = encodeMime128("text/plain; c=d; a=b");
        assertTrue(this.doHash(a) != this.doHash(b));
    }
}
