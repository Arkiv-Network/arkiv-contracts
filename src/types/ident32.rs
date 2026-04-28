use alloy_primitives::B256;
use eyre::{Result, bail};

/// Valid character bitmap: a-z, 0-9, '.', '-', '_'.
/// Mirrors IDENT_CHARSET in Ident32.sol.
const IDENT_CHARSET: u128 = (1 << 0x2D) | (1 << 0x2E)         // hyphen, dot
    | (((1 << 10) - 1) << 0x30)                                 // digits
    | (1 << 0x5F)                                                // underscore
    | (((1u128 << 26) - 1) << 0x61); // lowercase a-z

/// Leading byte bitmap: a-z only.
const IDENT_LEADING: u128 = ((1u128 << 26) - 1) << 0x61;

/// A validated 32-byte left-aligned ASCII identifier, mirroring the Solidity `Ident32` UDVT.
///
/// Valid characters: `a-z`, `0-9`, `.`, `-`, `_`. Must start with `a-z`.
/// Stored as left-aligned bytes in a `B256`, null-padded on the right.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Ident32(B256);

impl Ident32 {
    /// Encode a string into an Ident32, validating the charset.
    pub fn encode(s: &str) -> Result<Self> {
        let bytes = s.as_bytes();
        if bytes.is_empty() {
            bail!("Ident32 cannot be empty");
        }
        if bytes.len() > 32 {
            bail!("Ident32 too long: {} bytes (max 32)", bytes.len());
        }

        // Leading byte must be a-z
        if (IDENT_LEADING >> bytes[0]) & 1 == 0 {
            bail!(
                "Ident32 invalid leading byte at position 0: 0x{:02x}",
                bytes[0]
            );
        }

        // Remaining bytes must be in IDENT_CHARSET
        for (i, &b) in bytes.iter().enumerate().skip(1) {
            if (IDENT_CHARSET >> b) & 1 == 0 {
                bail!("Ident32 invalid byte at position {}: 0x{:02x}", i, b);
            }
        }

        let mut buf = [0u8; 32];
        buf[..bytes.len()].copy_from_slice(bytes);
        Ok(Self(B256::from(buf)))
    }

    /// Decode an Ident32 back to a string, stripping null padding.
    pub fn decode(raw: B256) -> Result<String> {
        let bytes: &[u8] = raw.as_ref();
        let end = bytes.iter().position(|b| *b == 0).unwrap_or(32);
        String::from_utf8(bytes[..end].to_vec())
            .map_err(|e| eyre::eyre!("invalid UTF-8 in Ident32: {}", e))
    }

    /// Get the raw B256 representation.
    pub fn as_b256(&self) -> B256 {
        self.0
    }

    /// Decode this Ident32 to a string.
    pub fn to_string(&self) -> Result<String> {
        Self::decode(self.0)
    }
}

impl TryFrom<&str> for Ident32 {
    type Error = eyre::Error;
    fn try_from(s: &str) -> Result<Self> {
        Self::encode(s)
    }
}

impl TryFrom<B256> for Ident32 {
    type Error = eyre::Error;
    fn try_from(raw: B256) -> Result<Self> {
        // Validate the raw bytes
        let s = Self::decode(raw)?;
        Self::encode(&s)
    }
}

impl From<Ident32> for B256 {
    fn from(id: Ident32) -> B256 {
        id.0
    }
}

impl std::fmt::Display for Ident32 {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self.to_string() {
            Ok(s) => write!(f, "{}", s),
            Err(_) => write!(f, "{}", self.0),
        }
    }
}

#[cfg(feature = "serde-wire")]
impl serde::Serialize for Ident32 {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        // Always Ok by construction — `Ident32::encode` and the
        // `TryFrom<B256>` impl both validate UTF-8 + charset before
        // building the value, so `to_string` cannot fail here.
        let s = self.to_string().map_err(serde::ser::Error::custom)?;
        serializer.serialize_str(&s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_decode_roundtrip() {
        let id = Ident32::encode("my.attribute").unwrap();
        let decoded = id.to_string().unwrap();
        assert_eq!(decoded, "my.attribute");
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
    fn full_length() {
        let s = "a".repeat(32);
        let id = Ident32::encode(&s).unwrap();
        assert_eq!(id.to_string().unwrap().len(), 32);
    }
}
