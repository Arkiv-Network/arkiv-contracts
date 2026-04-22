// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @dev 128-byte MIME type descriptor. Fits types with parameters like
/// "text/plain; charset=utf-8". Wraps bytes32[4] for compile-time type safety.
/// EIP-712 typehash encoding uses the underlying bytes32[4] directly.
struct Mime128 {
    bytes32[4] data;
}

error MimeEmpty();
error MimeTooLong(uint256 length, uint256 maxLength);
error MimeInvalidByte(uint256 position, bytes1 value);
error MimeIncomplete();

/// @dev Bitmap of valid bytes for MIME fields (broad).
/// Valid: printable ASCII 0x20–0x7E, excluding uppercase A-Z (0x41–0x5A).
///   bits 32–64  (0x20–0x40): set
///   bits 65–90  (0x41–0x5A): unset  (uppercase)
///   bits 91–126 (0x5B–0x7E): set
uint256 constant LOWER_PRINTABLE_ASCII = (((1 << 33) - 1) << 32) | (((1 << 36) - 1) << 91);

/// @dev Bitmap of valid MIME token characters (RFC 2045, lowercase only).
/// Token: printable ASCII excluding SPACE, CTLs, tspecials, and uppercase.
/// tspecials: " ( ) , / : ; < = > ? @ [ \ ]
uint256 constant MIME_TOKEN = LOWER_PRINTABLE_ASCII
    & ~uint256(
        (1 << 0x20) // space
            | (1 << 0x22) // "
            | (1 << 0x28) // (
            | (1 << 0x29) // )
            | (1 << 0x2C) // ,
            | (1 << 0x2F) // /
            | (1 << 0x3A) // :
            | (1 << 0x3B) // ;
            | (1 << 0x3C) // <
            | (1 << 0x3D) // =
            | (1 << 0x3E) // >
            | (1 << 0x3F) // ?
            | (1 << 0x40) // @
            | (1 << 0x5B) // [
            | (1 << 0x5C) // \
            | (1 << 0x5D) // ]
    );

// State machine states for MIME type structural validation.
//
//   TYPE ──token──→ TYPE
//        ──  /   ──→ SUBTYPE
//
//   SUBTYPE ──token──→ SUBTYPE
//           ──  ;   ──→ OWS
//           ──  \0  ──→ END
//
//   OWS ──  ' ' ──→ OWS
//       ──token──→ PNAME
//
//   PNAME ──token──→ PNAME
//         ──  =   ──→ PVALUE
//
//   PVALUE ──token──→ PVALUE
//          ──  ;   ──→ OWS
//          ──  \0  ──→ END
uint8 constant S_TYPE = 0;
uint8 constant S_SUBTYPE = 1;
uint8 constant S_OWS = 2;
uint8 constant S_PNAME = 3;
uint8 constant S_PVALUE = 4;

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

/// @notice Validate MIME type structure and charset per RFC 2045.
/// @dev Single-pass state machine. Token positions use MIME_TOKEN bitmap.
/// Structural characters (/ ; = space) are valid only in the state where
/// they trigger a transition. Each segment (type, subtype, param name,
/// param value) must be non-empty.
/// @return len Byte length of the content (up to first zero byte).
function validateMime128(Mime128 calldata m) pure returns (uint256 len) {
    uint8 state = S_TYPE;
    uint256 segLen;

    for (uint256 i = 0; i < 4; i++) {
        bytes32 word = m.data[i];
        for (uint256 j = 0; j < 32; j++) {
            uint8 b = uint8(word[j]);
            uint256 pos = i * 32 + j;

            // Zero byte — end of content.
            if (b == 0) {
                if (len == 0) revert MimeEmpty();
                if ((state == S_SUBTYPE || state == S_PVALUE) && segLen > 0) return len;
                revert MimeIncomplete();
            }

            if (state == S_TYPE) {
                if ((MIME_TOKEN >> b) & 1 == 1) {
                    segLen++;
                } else if (b == 0x2F && segLen > 0) {
                    state = S_SUBTYPE;
                    segLen = 0;
                } else {
                    revert MimeInvalidByte(pos, bytes1(b));
                }
            } else if (state == S_SUBTYPE) {
                if ((MIME_TOKEN >> b) & 1 == 1) {
                    segLen++;
                } else if (b == 0x3B && segLen > 0) {
                    state = S_OWS;
                    segLen = 0;
                } else {
                    revert MimeInvalidByte(pos, bytes1(b));
                }
            } else if (state == S_OWS) {
                if (b == 0x20) {
                    // stay — optional whitespace
                } else if ((MIME_TOKEN >> b) & 1 == 1) {
                    state = S_PNAME;
                    segLen = 1;
                } else {
                    revert MimeInvalidByte(pos, bytes1(b));
                }
            } else if (state == S_PNAME) {
                if ((MIME_TOKEN >> b) & 1 == 1) {
                    segLen++;
                } else if (b == 0x3D && segLen > 0) {
                    state = S_PVALUE;
                    segLen = 0;
                } else {
                    revert MimeInvalidByte(pos, bytes1(b));
                }
            } else if (state == S_PVALUE) {
                if ((MIME_TOKEN >> b) & 1 == 1) {
                    segLen++;
                } else if (b == 0x3B && segLen > 0) {
                    state = S_OWS;
                    segLen = 0;
                } else {
                    revert MimeInvalidByte(pos, bytes1(b));
                }
            }

            len++;
        }
    }

    // All 128 bytes consumed, no zero terminator.
    if (len == 0) revert MimeEmpty();
    if ((state == S_SUBTYPE || state == S_PVALUE) && segLen > 0) return len;
    revert MimeIncomplete();
}

/// @notice Compute the lookup key for a Mime128 (calldata).
function mime128Hash(Mime128 calldata m) pure returns (bytes32) {
    return keccak256(abi.encode(m.data[0], m.data[1], m.data[2], m.data[3]));
}

/// @notice Compute the lookup key for a Mime128 (memory).
function mime128HashM(Mime128 memory m) pure returns (bytes32) {
    return keccak256(abi.encode(m.data[0], m.data[1], m.data[2], m.data[3]));
}
