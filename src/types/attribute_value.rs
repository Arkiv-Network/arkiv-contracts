//! Typed decoder for the on-chain `bytes32[4]` attribute value container.
//!
//! Encoding rules per `docs/value128-encoding.md`:
//!
//! | `valueType`        | `data[0]`                  | `data[1..=3]`            | Alignment      |
//! |--------------------|----------------------------|--------------------------|----------------|
//! | `ATTR_UINT`        | `bytes32(uint256)`         | zero                     | right-aligned  |
//! | `ATTR_STRING`      | First 32 bytes of payload  | continuation + 0-padding | left-aligned   |
//! | `ATTR_ENTITY_KEY`  | entity key (`bytes32`)     | zero                     | full word      |
//!
//! Natural sizes per type:
//!
//! - `ATTR_UINT` and `ATTR_ENTITY_KEY` are `bytes32` values — only `data[0]`
//!   carries the payload. The decoder requires `data[1..=3]` to be zero and
//!   rejects malformed encodings.
//! - `ATTR_STRING` is `bytes32[4]` — it owns the full 128-byte container.
//!   Content is opaque bytes (UTF-8 by convention, not enforcement);
//!   consumers that want a `String` should call `String::from_utf8`
//!   (strict) or `String::from_utf8_lossy` (permissive) on the returned bytes.
//!
//! Failure modes: unknown `value_type`, or non-zero `data[1..=3]` for the
//! single-word types. Byte content of `ATTR_STRING` is never rejected.

use alloy_primitives::{B256, Bytes, U256};
use eyre::{Result, bail};

use crate::types::DecodedAttribute;
use crate::{ATTR_ENTITY_KEY, ATTR_STRING, ATTR_UINT};

/// A decoded attribute value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttributeValue {
    /// `ATTR_UINT`: `bytes32` value carrying a right-aligned uint256 in
    /// `data[0]`.
    Uint(U256),
    /// `ATTR_STRING`: `bytes32[4]` of opaque bytes, truncated at the first
    /// NUL byte. UTF-8 by convention, not enforcement.
    Bytes(Bytes),
    /// `ATTR_ENTITY_KEY`: `bytes32` value carrying an entity key in `data[0]`.
    EntityKey(B256),
}

/// Decode the typed value out of an attribute according to its `value_type`.
pub fn decode_attribute_value(attr: &DecodedAttribute) -> Result<AttributeValue> {
    match attr.value_type {
        ATTR_UINT => {
            require_single_word(attr)?;
            Ok(AttributeValue::Uint(U256::from_be_bytes(
                attr.raw_value[0].0,
            )))
        }
        ATTR_STRING => Ok(AttributeValue::Bytes(decode_string_bytes(&attr.raw_value))),
        ATTR_ENTITY_KEY => {
            require_single_word(attr)?;
            Ok(AttributeValue::EntityKey(attr.raw_value[0]))
        }
        other => bail!("unknown attribute value_type: {}", other),
    }
}

/// Enforce the `bytes32`-sized variant invariant: `data[1..=3]` must be zero.
fn require_single_word(attr: &DecodedAttribute) -> Result<()> {
    for (i, w) in attr.raw_value.iter().enumerate().skip(1) {
        if *w != B256::ZERO {
            bail!(
                "value_type {} expects bytes32 (data[1..=3] zero), but data[{}] is non-zero",
                attr.value_type,
                i,
            );
        }
    }
    Ok(())
}

/// Concatenate the four 32-byte words and truncate at the first NUL.
fn decode_string_bytes(words: &[B256; 4]) -> Bytes {
    let mut buf = Vec::with_capacity(128);
    for w in words {
        buf.extend_from_slice(w.as_slice());
    }
    if let Some(nul) = buf.iter().position(|b| *b == 0) {
        buf.truncate(nul);
    }
    Bytes::from(buf)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::FixedBytes;

    /// Build a `DecodedAttribute` with the given raw words. The `name` is
    /// irrelevant for value decoding; tests use a placeholder.
    fn attr(value_type: u8, raw_value: [B256; 4]) -> DecodedAttribute {
        DecodedAttribute {
            name: "test".to_string(),
            value_type,
            raw_value,
        }
    }

    /// Right-align a `U256` into a single `B256` (matches `bytes32(uint256)`).
    fn encode_uint(v: U256) -> [B256; 4] {
        [B256::from(v), B256::ZERO, B256::ZERO, B256::ZERO]
    }

    /// Left-align bytes into four words with zero padding (matches the
    /// Solidity packing for ATTR_STRING).
    fn encode_bytes(b: &[u8]) -> [B256; 4] {
        assert!(b.len() <= 128, "test payload too long");
        let mut buf = [0u8; 128];
        buf[..b.len()].copy_from_slice(b);
        let mut words = [B256::ZERO; 4];
        for (i, w) in words.iter_mut().enumerate() {
            *w = B256::from_slice(&buf[i * 32..(i + 1) * 32]);
        }
        words
    }

    #[test]
    fn uint_roundtrip_zero() {
        let a = attr(ATTR_UINT, encode_uint(U256::ZERO));
        assert_eq!(
            decode_attribute_value(&a).unwrap(),
            AttributeValue::Uint(U256::ZERO)
        );
    }

    #[test]
    fn uint_roundtrip_small() {
        let a = attr(ATTR_UINT, encode_uint(U256::from(42u64)));
        assert_eq!(
            decode_attribute_value(&a).unwrap(),
            AttributeValue::Uint(U256::from(42u64))
        );
    }

    #[test]
    fn uint_roundtrip_max() {
        let a = attr(ATTR_UINT, encode_uint(U256::MAX));
        assert_eq!(
            decode_attribute_value(&a).unwrap(),
            AttributeValue::Uint(U256::MAX)
        );
    }

    #[test]
    fn uint_rejects_nonzero_higher_words() {
        // ATTR_UINT is bytes32-sized; data[1..=3] must be zero.
        let mut raw = encode_uint(U256::from(7u64));
        raw[1] = B256::repeat_byte(0xFF);
        let a = attr(ATTR_UINT, raw);
        let err = decode_attribute_value(&a).unwrap_err().to_string();
        assert!(
            err.contains("data[1]"),
            "error should locate the bad slot: {}",
            err
        );
    }

    #[test]
    fn uint_rejects_nonzero_at_data3() {
        // Bound check: violation in the *last* slot is also rejected.
        let mut raw = encode_uint(U256::from(7u64));
        raw[3] = B256::repeat_byte(0xAB);
        let a = attr(ATTR_UINT, raw);
        assert!(decode_attribute_value(&a).is_err());
    }

    #[test]
    fn bytes_roundtrip_short() {
        let a = attr(ATTR_STRING, encode_bytes(b"hello"));
        assert_eq!(
            decode_attribute_value(&a).unwrap(),
            AttributeValue::Bytes(Bytes::from_static(b"hello"))
        );
    }

    #[test]
    fn bytes_roundtrip_empty() {
        let a = attr(ATTR_STRING, encode_bytes(b""));
        assert_eq!(
            decode_attribute_value(&a).unwrap(),
            AttributeValue::Bytes(Bytes::new())
        );
    }

    #[test]
    fn bytes_roundtrip_spans_multiple_words() {
        // 50 bytes — straddles the data[0]/data[1] boundary.
        let s = b"hello world this string is longer than thirty two!";
        assert_eq!(s.len(), 50);
        let a = attr(ATTR_STRING, encode_bytes(s));
        assert_eq!(
            decode_attribute_value(&a).unwrap(),
            AttributeValue::Bytes(Bytes::copy_from_slice(s))
        );
    }

    #[test]
    fn bytes_roundtrip_full_128_no_nul() {
        // Maximum length with no NUL — every byte is meaningful.
        let s = vec![b'x'; 128];
        let a = attr(ATTR_STRING, encode_bytes(&s));
        assert_eq!(
            decode_attribute_value(&a).unwrap(),
            AttributeValue::Bytes(Bytes::from(s))
        );
    }

    #[test]
    fn bytes_truncates_at_first_nul() {
        // Manually craft a value with a NUL in the middle — bytes after
        // the NUL are dropped, even if non-zero.
        let mut buf = [0u8; 128];
        buf[..5].copy_from_slice(b"hello");
        buf[10..15].copy_from_slice(b"junk!");
        let mut words = [B256::ZERO; 4];
        for (i, w) in words.iter_mut().enumerate() {
            *w = B256::from_slice(&buf[i * 32..(i + 1) * 32]);
        }
        let a = attr(ATTR_STRING, words);
        assert_eq!(
            decode_attribute_value(&a).unwrap(),
            AttributeValue::Bytes(Bytes::from_static(b"hello"))
        );
    }

    #[test]
    fn bytes_passes_through_invalid_utf8() {
        // Decoder is opaque: invalid UTF-8 is returned verbatim, not rejected.
        let mut w0 = [0u8; 32];
        w0[0] = 0xFF;
        w0[1] = 0xFE;
        // No NUL, so the full 128 bytes come back; pad the rest with 0xAA so
        // they survive truncation.
        let mut raw = [B256::ZERO; 4];
        raw[0] = B256::from(w0);
        raw[1] = B256::repeat_byte(0xAA);
        raw[2] = B256::repeat_byte(0xAA);
        raw[3] = B256::repeat_byte(0xAA);
        // Manually rebuild the expected bytes (truncates at the first NUL,
        // which lives at w0[2]).
        let expected = vec![0xFFu8, 0xFE];
        let a = attr(ATTR_STRING, raw);
        assert_eq!(
            decode_attribute_value(&a).unwrap(),
            AttributeValue::Bytes(Bytes::from(expected))
        );
    }

    #[test]
    fn entity_key_roundtrip() {
        let key = B256::repeat_byte(0xAB);
        let a = attr(ATTR_ENTITY_KEY, [key, B256::ZERO, B256::ZERO, B256::ZERO]);
        assert_eq!(
            decode_attribute_value(&a).unwrap(),
            AttributeValue::EntityKey(key)
        );
    }

    #[test]
    fn entity_key_rejects_nonzero_higher_words() {
        // ATTR_ENTITY_KEY is bytes32-sized; data[1..=3] must be zero.
        let key = B256::repeat_byte(0x42);
        let a = attr(
            ATTR_ENTITY_KEY,
            [key, B256::ZERO, B256::ZERO, FixedBytes([0x77u8; 32])],
        );
        let err = decode_attribute_value(&a).unwrap_err().to_string();
        assert!(
            err.contains("data[3]"),
            "error should locate the bad slot: {}",
            err
        );
    }

    #[test]
    fn unknown_discriminator_errors() {
        let a = attr(0, [B256::ZERO; 4]);
        assert!(decode_attribute_value(&a).is_err());

        let a = attr(99, [B256::ZERO; 4]);
        let err = decode_attribute_value(&a).unwrap_err().to_string();
        assert!(
            err.contains("99"),
            "error should mention the bad value_type: {}",
            err
        );
    }
}
