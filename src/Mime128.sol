// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev 128-byte MIME type descriptor. Fits types with parameters like
/// "text/plain; charset=utf-8". Wraps bytes32[4] for compile-time type safety.
/// EIP-712 typehash encoding uses the underlying bytes32[4] directly.
struct Mime128 {
    bytes32[4] data;
}

error MimeEmpty();
error MimeTooLong(uint256 length, uint256 maxLength);
error MimeInvalidByte(uint256 position, bytes1 value);

/// @dev Bitmap of valid bytes for MIME fields.
/// Valid: printable ASCII 0x20–0x7E, excluding uppercase A-Z (0x41–0x5A).
/// Covers MIME type/subtype tokens and parameters per RFC 2045.
///   bits 32–64  (0x20–0x40): set
///   bits 65–90  (0x41–0x5A): unset  (uppercase)
///   bits 91–126 (0x5B–0x7E): set
uint256 constant LOWER_PRINTABLE_ASCII = (((1 << 33) - 1) << 32) | (((1 << 36) - 1) << 91);

/// @notice Encode a string into a Mime128. Left-aligned, zero-padded.
/// Reverts if empty or longer than 128 bytes.
function encodeMime128(string memory value) pure returns (Mime128 memory m) {
    bytes memory b = bytes(value);
    if (b.length == 0) revert MimeEmpty();
    if (b.length > 128) revert MimeTooLong(b.length, 128);
    for (uint256 i = 0; i < b.length; i++) {
        uint256 slot = i / 32;
        uint256 offset = i % 32;
        m.data[slot] |= bytes32(bytes1(b[i])) >> (offset * 8);
    }
}

/// @notice Decode a Mime128 back into a string.
/// Strips trailing zero bytes to recover the original length.
function decodeMime128(Mime128 memory m) pure returns (string memory) {
    bytes memory buf = new bytes(128);
    for (uint256 i = 0; i < 4; i++) {
        bytes32 word = m.data[i];
        for (uint256 j = 0; j < 32; j++) {
            buf[i * 32 + j] = word[j];
        }
    }
    uint256 len = 128;
    while (len > 0 && buf[len - 1] == 0) {
        len--;
    }
    assembly {
        mstore(buf, len)
    }
    return string(buf);
}

/// @notice Validate a Mime128 contains only lowercase printable ASCII.
/// @return len Byte length of the content (up to first zero byte).
function validateMime128(Mime128 calldata m) pure returns (uint256 len) {
    for (uint256 i = 0; i < 4; i++) {
        bytes32 word = m.data[i];
        for (uint256 j = 0; j < 32; j++) {
            uint8 b = uint8(word[j]);
            if (b == 0) {
                if (len == 0) revert MimeEmpty();
                return len;
            }
            if ((LOWER_PRINTABLE_ASCII >> b) & 1 == 0) {
                revert MimeInvalidByte(i * 32 + j, bytes1(b));
            }
            len++;
        }
    }
    if (len == 0) revert MimeEmpty();
}

/// @notice Compute the lookup key for a Mime128 (calldata).
function mime128Hash(Mime128 calldata m) pure returns (bytes32) {
    return keccak256(abi.encode(m.data[0], m.data[1], m.data[2], m.data[3]));
}

/// @notice Compute the lookup key for a Mime128 (memory).
function mime128HashM(Mime128 memory m) pure returns (bytes32) {
    return keccak256(abi.encode(m.data[0], m.data[1], m.data[2], m.data[3]));
}
