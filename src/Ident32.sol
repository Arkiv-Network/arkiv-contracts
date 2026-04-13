// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

error Ident32Empty();
error Ident32TooLong(uint256 length);
error Ident32InvalidByte(uint256 position, bytes1 value);

/// @dev Bitmap of valid identifier characters: a-z, 0-9, '.', '-', '_'.
///   bits 45–46  (0x2D–0x2E): set  (hyphen, dot)
///   bits 48–57  (0x30–0x39): set  (digits)
///   bit  95     (0x5F):      set  (underscore)
///   bits 97–122 (0x61–0x7A): set  (lowercase)
uint256 constant IDENT_CHARSET =
    (1 << 0x2D) | (1 << 0x2E) | (((1 << 10) - 1) << 0x30) | (1 << 0x5F) | (((1 << 26) - 1) << 0x61);

/// @dev Bitmap for the leading byte: a-z only.
///   bits 97–122 (0x61–0x7A): set
uint256 constant IDENT_LEADING = ((1 << 26) - 1) << 0x61;

/// @notice Encode a string into a left-aligned, zero-padded bytes32.
/// Reverts if empty or longer than 32 bytes.
function encodeIdent32(string memory value) pure returns (bytes32 result) {
    bytes memory b = bytes(value);
    if (b.length == 0) revert Ident32Empty();
    if (b.length > 32) revert Ident32TooLong(b.length);
    assembly {
        result := mload(add(b, 32))
    }
}

/// @notice Decode a bytes32 back into a string.
/// Strips trailing zero bytes to recover the original length.
function decodeIdent32(bytes32 value) pure returns (string memory) {
    bytes memory buf = new bytes(32);
    assembly {
        mstore(add(buf, 32), value)
    }
    uint256 len = 32;
    while (len > 0 && buf[len - 1] == 0) {
        len--;
    }
    assembly {
        mstore(buf, len)
    }
    return string(buf);
}

/// @notice Validate that a bytes32 is a valid identifier.
/// @dev Leading byte must be a-z. Subsequent bytes must be in IDENT_CHARSET
/// (a-z, 0-9, '.', '-', '_'). Once a zero byte is encountered, all remaining
/// bytes must also be zero (left-aligned, no embedded nulls).
/// @return len The number of non-zero bytes (1–32).
function validateIdent32(bytes32 value) pure returns (uint256 len) {
    uint8 b0 = uint8(value[0]);
    if (b0 == 0) revert Ident32Empty();
    if ((IDENT_LEADING >> b0) & 1 == 0) revert Ident32InvalidByte(0, bytes1(b0));
    len = 1;

    for (uint256 j = 1; j < 32; j++) {
        uint8 b = uint8(value[j]);
        if (b == 0) {
            // Verify remaining bytes are all zero (no embedded nulls).
            for (uint256 k = j + 1; k < 32; k++) {
                if (uint8(value[k]) != 0) {
                    revert Ident32InvalidByte(k, bytes1(uint8(value[k])));
                }
            }
            return len;
        }
        if ((IDENT_CHARSET >> b) & 1 == 0) {
            revert Ident32InvalidByte(j, bytes1(b));
        }
        len++;
    }
}
