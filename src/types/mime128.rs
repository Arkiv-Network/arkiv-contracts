use alloy_primitives::FixedBytes;
use eyre::{Result, bail};

/// Valid MIME token characters (RFC 2045, lowercase only).
/// Mirrors MIME_TOKEN in Mime128.sol.
const MIME_TOKEN: u128 = LOWER_PRINTABLE_ASCII
    & !((1 << 0x20) // space
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
        | (1 << 0x5D)); // ]

/// Printable ASCII excluding uppercase.
const LOWER_PRINTABLE_ASCII: u128 = (((1u128 << 33) - 1) << 32) | (((1u128 << 36) - 1) << 91);

const S_TYPE: u8 = 0;
const S_SUBTYPE: u8 = 1;
const S_OWS: u8 = 2;
const S_PNAME: u8 = 3;
const S_PVALUE: u8 = 4;

fn is_token(b: u8) -> bool {
    b < 128 && (MIME_TOKEN >> b) & 1 == 1
}

/// A validated 128-byte MIME type string, mirroring the Solidity `Mime128` struct.
///
/// Stored as 4 × bytes32 (left-aligned, null-padded).
/// Validated per RFC 2045: `type/subtype[; param=value]*`, lowercase only.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mime128Str(String);

impl Mime128Str {
    /// Encode and validate a MIME string.
    pub fn encode(s: &str) -> Result<Self> {
        let bytes = s.as_bytes();
        if bytes.is_empty() {
            bail!("MIME type cannot be empty");
        }
        if bytes.len() > 128 {
            bail!("MIME type too long: {} bytes (max 128)", bytes.len());
        }
        validate_mime(bytes)?;
        Ok(Self(s.to_string()))
    }

    /// Decode from the raw 4 × bytes32 representation.
    pub fn decode(data: &[FixedBytes<32>; 4]) -> Option<String> {
        let mut bytes = Vec::with_capacity(128);
        for b32 in data {
            bytes.extend_from_slice(&b32[..]);
        }
        if let Some(end) = bytes.iter().position(|b| *b == 0) {
            bytes.truncate(end);
        }
        String::from_utf8(bytes).ok()
    }

    /// Encode into the raw 4 × bytes32 representation.
    pub fn to_bytes32x4(&self) -> [FixedBytes<32>; 4] {
        let bytes = self.0.as_bytes();
        let mut data = [FixedBytes::ZERO; 4];
        for (i, chunk) in bytes.chunks(32).enumerate() {
            if i >= 4 {
                break;
            }
            let mut buf = [0u8; 32];
            buf[..chunk.len()].copy_from_slice(chunk);
            data[i] = FixedBytes::from(buf);
        }
        data
    }

    /// Get the string value.
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl TryFrom<&str> for Mime128Str {
    type Error = eyre::Error;
    fn try_from(s: &str) -> Result<Self> {
        Self::encode(s)
    }
}

/// Decode + validate the sol!-generated `Mime128` struct in one step.
///
/// Symmetric counterpart of [`Mime128Str::to_bytes32x4`] composed into the
/// `Mime128 { data }` wrapper: bytes → string → validated MIME.
impl TryFrom<&crate::Mime128> for Mime128Str {
    type Error = eyre::Error;
    fn try_from(mime: &crate::Mime128) -> Result<Self> {
        let s = Self::decode(&mime.data).ok_or_else(|| eyre::eyre!("invalid UTF-8 in Mime128"))?;
        Self::encode(&s)
    }
}

impl std::fmt::Display for Mime128Str {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// Validate MIME structure per RFC 2045 state machine (mirrors Mime128.sol).
fn validate_mime(bytes: &[u8]) -> Result<()> {
    let mut state = S_TYPE;
    let mut seg_len: usize = 0;

    for (pos, &b) in bytes.iter().enumerate() {
        match state {
            S_TYPE => {
                if is_token(b) {
                    seg_len += 1;
                } else if b == b'/' && seg_len > 0 {
                    state = S_SUBTYPE;
                    seg_len = 0;
                } else {
                    bail!("MIME invalid byte at position {}: 0x{:02x}", pos, b);
                }
            }
            S_SUBTYPE => {
                if is_token(b) {
                    seg_len += 1;
                } else if b == b';' && seg_len > 0 {
                    state = S_OWS;
                    seg_len = 0;
                } else {
                    bail!("MIME invalid byte at position {}: 0x{:02x}", pos, b);
                }
            }
            S_OWS => {
                if b == b' ' {
                    // stay
                } else if is_token(b) {
                    state = S_PNAME;
                    seg_len = 1;
                } else {
                    bail!("MIME invalid byte at position {}: 0x{:02x}", pos, b);
                }
            }
            S_PNAME => {
                if is_token(b) {
                    seg_len += 1;
                } else if b == b'=' && seg_len > 0 {
                    state = S_PVALUE;
                    seg_len = 0;
                } else {
                    bail!("MIME invalid byte at position {}: 0x{:02x}", pos, b);
                }
            }
            S_PVALUE => {
                if is_token(b) {
                    seg_len += 1;
                } else if b == b';' && seg_len > 0 {
                    state = S_OWS;
                    seg_len = 0;
                } else {
                    bail!("MIME invalid byte at position {}: 0x{:02x}", pos, b);
                }
            }
            _ => unreachable!(),
        }
    }

    // Must end in SUBTYPE or PVALUE with non-empty segment
    if (state == S_SUBTYPE || state == S_PVALUE) && seg_len > 0 {
        Ok(())
    } else {
        bail!("MIME type incomplete")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_decode_roundtrip() {
        let m = Mime128Str::encode("application/json").unwrap();
        let raw = m.to_bytes32x4();
        let decoded = Mime128Str::decode(&raw).unwrap();
        assert_eq!(decoded, "application/json");
    }

    #[test]
    fn with_params() {
        let m = Mime128Str::encode("text/plain; charset=utf-8").unwrap();
        assert_eq!(m.as_str(), "text/plain; charset=utf-8");
    }

    #[test]
    fn rejects_empty() {
        assert!(Mime128Str::encode("").is_err());
    }

    #[test]
    fn rejects_uppercase() {
        assert!(Mime128Str::encode("Application/JSON").is_err());
    }

    #[test]
    fn rejects_missing_subtype() {
        assert!(Mime128Str::encode("text").is_err());
    }

    #[test]
    fn rejects_incomplete_param() {
        assert!(Mime128Str::encode("text/plain; charset").is_err());
    }

    #[test]
    fn max_length() {
        let s = format!("{}/{}", "a".repeat(63), "b".repeat(64));
        assert!(Mime128Str::encode(&s).is_ok());
    }

    #[test]
    fn rejects_too_long() {
        let s = format!("{}/{}", "a".repeat(64), "b".repeat(64));
        assert!(Mime128Str::encode(&s).is_err());
    }

    #[test]
    fn try_from_mime128_roundtrip() {
        let m = Mime128Str::encode("text/plain; charset=utf-8").unwrap();
        let mime = crate::Mime128 {
            data: m.to_bytes32x4(),
        };
        let recovered = Mime128Str::try_from(&mime).unwrap();
        assert_eq!(recovered, m);
    }

    #[test]
    fn try_from_mime128_rejects_invalid_utf8() {
        let mut w0 = [0u8; 32];
        w0[0] = 0xFF; // invalid UTF-8 leading byte
        let mime = crate::Mime128 {
            data: [
                FixedBytes::from(w0),
                FixedBytes::ZERO,
                FixedBytes::ZERO,
                FixedBytes::ZERO,
            ],
        };
        assert!(Mime128Str::try_from(&mime).is_err());
    }

    #[test]
    fn try_from_mime128_rejects_invalid_mime_structure() {
        // Valid UTF-8 bytes that fail MIME validation (uppercase, lowercase-only rule).
        let mut w0 = [0u8; 32];
        w0[..16].copy_from_slice(b"Application/JSON");
        let mime = crate::Mime128 {
            data: [
                FixedBytes::from(w0),
                FixedBytes::ZERO,
                FixedBytes::ZERO,
                FixedBytes::ZERO,
            ],
        };
        assert!(Mime128Str::try_from(&mime).is_err());
    }
}
