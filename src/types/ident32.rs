//! Validation and string-conversion impls for the ABI-generated [`Ident32`] UDVT.
//!
//! [`Ident32`] is a left-aligned, null-padded 32-byte ASCII identifier.
//! Valid characters: `a-z`, `0-9`, `.`, `-`, `_`. Must start with `a-z`.
//!
//! These impl blocks mirror the validation rules in `contracts/types/Ident32.sol`.

use alloy_primitives::FixedBytes;
use eyre::{Result, bail};

use crate::Ident32;

/// Valid character bitmap: a-z, 0-9, '.', '-', '_'.
/// Mirrors `IDENT_CHARSET` in Ident32.sol.
const IDENT_CHARSET: u128 = (1 << 0x2D) | (1 << 0x2E)
    | (((1 << 10) - 1) << 0x30)
    | (1 << 0x5F)
    | (((1u128 << 26) - 1) << 0x61);

/// Leading byte bitmap: a-z only.
/// Mirrors `IDENT_LEADING` in Ident32.sol.
const IDENT_LEADING: u128 = ((1u128 << 26) - 1) << 0x61;

impl Ident32 {
    /// Encode a string into an `Ident32`, validating the charset.
    ///
    /// Rules (mirrors `validateIdent32` in Ident32.sol):
    /// - Non-empty, at most 32 bytes
    /// - First byte must be `a-z`
    /// - Remaining bytes must be in `a-z 0-9 . - _`
    pub fn encode(s: &str) -> Result<Self> {
        let bytes = s.as_bytes();
        if bytes.is_empty() {
            bail!("Ident32 cannot be empty");
        }
        if bytes.len() > 32 {
            bail!("Ident32 too long: {} bytes (max 32)", bytes.len());
        }
        if (IDENT_LEADING >> bytes[0]) & 1 == 0 {
            bail!("Ident32 invalid leading byte at position 0: 0x{:02x}", bytes[0]);
        }
        for (i, &b) in bytes.iter().enumerate().skip(1) {
            if (IDENT_CHARSET >> b) & 1 == 0 {
                bail!("Ident32 invalid byte at position {}: 0x{:02x}", i, b);
            }
        }
        let mut buf = [0u8; 32];
        buf[..bytes.len()].copy_from_slice(bytes);
        Ok(Self(FixedBytes::from(buf)))
    }

    /// Decode an `Ident32` to its string representation, stripping null padding.
    pub fn decode(&self) -> Result<String> {
        let bytes = self.0.as_slice();
        let end = bytes.iter().position(|&b| b == 0).unwrap_or(32);
        String::from_utf8(bytes[..end].to_vec())
            .map_err(|e| eyre::eyre!("invalid UTF-8 in Ident32: {}", e))
    }

    /// Validate raw bytes as an `Ident32`, returning `self` if valid.
    ///
    /// In addition to charset validation, enforces that once a null byte
    /// appears all subsequent bytes must also be null (no embedded nulls).
    /// This matches the stricter check in `validateIdent32` in Ident32.sol.
    pub fn validate(self) -> Result<Self> {
        let bytes = self.0.as_slice();
        if bytes[0] == 0 {
            bail!("Ident32 cannot be empty");
        }
        if (IDENT_LEADING >> bytes[0]) & 1 == 0 {
            bail!("Ident32 invalid leading byte at position 0: 0x{:02x}", bytes[0]);
        }
        let mut found_null = false;
        for (i, &b) in bytes.iter().enumerate().skip(1) {
            if found_null {
                if b != 0 {
                    bail!("Ident32 embedded null: non-zero byte 0x{:02x} at position {}", b, i);
                }
            } else if b == 0 {
                found_null = true;
            } else if (IDENT_CHARSET >> b) & 1 == 0 {
                bail!("Ident32 invalid byte at position {}: 0x{:02x}", i, b);
            }
        }
        Ok(self)
    }
}

impl TryFrom<&str> for Ident32 {
    type Error = eyre::Error;
    fn try_from(s: &str) -> Result<Self> {
        Self::encode(s)
    }
}

impl std::fmt::Display for Ident32 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.decode() {
            Ok(s) => write!(f, "{}", s),
            Err(_) => write!(f, "{}", self.0),
        }
    }
}

#[cfg(feature = "serde-wire")]
impl serde::Serialize for Ident32 {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        // Always Ok by construction — values in scope are either produced by
        // `encode` (validated charset) or `validate` (same rules).
        let string = self.decode().map_err(serde::ser::Error::custom)?;
        s.serialize_str(&string)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_decode_roundtrip() {
        let id = Ident32::encode("my.attribute").unwrap();
        assert_eq!(id.decode().unwrap(), "my.attribute");
    }

    #[test]
    fn rejects_empty() {
        assert!(Ident32::encode("").is_err());
    }

    #[test]
    fn rejects_too_long() {
        let s = "a".repeat(33);
        assert!(Ident32::encode(&s).is_err());
    }

    #[test]
    fn rejects_uppercase() {
        assert!(Ident32::encode("Hello").is_err());
    }

    #[test]
    fn rejects_leading_digit() {
        assert!(Ident32::encode("1foo").is_err());
    }

    #[test]
    fn accepts_valid_chars() {
        assert!(Ident32::encode("my-attr_name.v2").is_ok());
    }

    #[test]
    fn full_length_32_bytes() {
        let s = "a".repeat(32);
        let id = Ident32::encode(&s).unwrap();
        assert_eq!(id.decode().unwrap().len(), 32);
    }

    #[test]
    fn validate_rejects_embedded_null() {
        // TryFrom<FixedBytes<32>> is provided by alloy (non-validating From).
        // Use Ident32(raw).validate() to enforce the contract's stricter check.
        let mut buf = [0u8; 32];
        buf[0] = b'a';
        buf[1] = b'b';
        buf[2] = 0;    // null terminator
        buf[3] = b'c'; // non-null after null — contract rejects this
        let raw = FixedBytes::<32>::from(buf);
        assert!(Ident32(raw).validate().is_err());
    }

    #[test]
    fn validate_accepts_null_terminated() {
        let mut buf = [0u8; 32];
        buf[0] = b'a';
        buf[1] = b'b';
        // remaining bytes are zero — valid
        let raw = FixedBytes::<32>::from(buf);
        assert!(Ident32(raw).validate().is_ok());
    }
}
