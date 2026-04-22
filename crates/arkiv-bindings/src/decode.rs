//! Decoding of EntityRegistry transactions from calldata and event logs.

use alloy_primitives::{Address, B256};
use alloy_sol_types::{SolCall, SolEvent};
use crate::{
    Attribute as AbiAttribute, Mime128, Operation as AbiOperation,
};
use crate::IEntityRegistry::{
    executeCall, EntityOperation as AbiEntityOperation,
};
use crate::types::{DecodedAttribute, DecodedOperation, EntityRecord};
use crate::{OP_CREATE, OP_UPDATE};
use eyre::{bail, Result};

/// Decode calldata + event logs from a transaction.
///
/// The caller is responsible for filtering to the correct contract address
/// before calling this function. Pass the registry address to filter logs.
///
/// For CREATE/UPDATE operations, decodes both calldata (for payload/attributes)
/// and logs (for entityKey/entityHash). For other operations, logs alone suffice.
pub fn decode_registry_transaction(
    registry_address: Address,
    tx_input: &[u8],
    tx_hash: B256,
    receipt_success: bool,
    receipt_logs: &[alloy_primitives::Log],
    block_number: u64,
) -> Result<Vec<DecodedOperation>> {
    // Skip failed transactions
    if !receipt_success {
        return Ok(Vec::new());
    }

    // Decode calldata to get operations
    let call = executeCall::abi_decode(tx_input).map_err(|e| {
        eyre::eyre!("failed to decode execute() calldata: {}", e)
    })?;

    let operations = &call.ops;

    // Extract EntityOperation events from logs
    let mut events = Vec::new();
    for log in receipt_logs {
        if log.address != registry_address {
            continue;
        }
        match AbiEntityOperation::decode_log_data(&log.data) {
            Ok(evt) => events.push(evt),
            Err(_) => continue,
        }
    }

    // Correlate: operations[i] in calldata matches events[i]
    if operations.len() != events.len() {
        bail!(
            "operation/event count mismatch: {} ops but {} events",
            operations.len(),
            events.len()
        );
    }

    let mut decoded = Vec::new();
    for (op, event) in operations.iter().zip(events.iter()) {
        let entity = match op.operationType {
            OP_CREATE | OP_UPDATE => Some(decode_entity_from_operation(op)?),
            _ => None,
        };

        decoded.push(DecodedOperation {
            block_number,
            tx_hash,
            op_type: op.operationType,
            entity_key: event.entityKey,
            owner: event.owner,
            expires_at: op.expiresAt,
            entity_hash: event.entityHash,
            entity,
        });
    }

    Ok(decoded)
}

/// Decode the full entity record from a CREATE or UPDATE operation.
fn decode_entity_from_operation(op: &AbiOperation) -> Result<EntityRecord> {
    let content_type = decode_mime128(&op.contentType);
    let mut attributes = Vec::new();

    for attr in &op.attributes {
        let decoded = decode_attribute(attr)?;
        attributes.push(decoded);
    }

    Ok(EntityRecord {
        entity_key: op.entityKey,
        creator: Address::ZERO,
        owner: Address::ZERO,
        created_at: 0,
        updated_at: 0,
        expires_at: op.expiresAt,
        core_hash: B256::ZERO,
        entity_hash: B256::ZERO,
        payload: Some(op.payload.clone()),
        content_type,
        attributes,
    })
}

/// Decode a Mime128 (4 x bytes32) to a string.
pub fn decode_mime128(mime: &Mime128) -> Option<String> {
    let mut bytes = Vec::with_capacity(128);
    for b32 in &mime.data {
        let slice = &b32[..];
        bytes.extend_from_slice(slice);
    }

    if let Some(null_pos) = bytes.iter().position(|b| *b == 0) {
        bytes.truncate(null_pos);
    }

    String::from_utf8(bytes).ok()
}

/// Decode an Attribute from calldata.
pub fn decode_attribute(attr: &AbiAttribute) -> Result<DecodedAttribute> {
    let name = decode_ident32(attr.name)?;

    Ok(DecodedAttribute {
        name,
        value_type: attr.valueType,
        raw_value: attr.value,
    })
}

/// Decode an Ident32 (bytes32 with left-aligned ASCII) to a string.
pub fn decode_ident32(ident: B256) -> Result<String> {
    let bytes: &[u8] = ident.as_ref();
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(32);
    String::from_utf8(bytes[..end].to_vec())
        .map_err(|e| eyre::eyre!("invalid UTF-8 in Ident32: {}", e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_mime128_with_nulls() {
        let mime = Mime128 {
            data: [
                B256::from_slice(&b"text/plain\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0"[..]),
                B256::ZERO,
                B256::ZERO,
                B256::ZERO,
            ],
        };
        let decoded = decode_mime128(&mime);
        assert_eq!(decoded, Some("text/plain".to_string()));
    }

    #[test]
    fn decode_ident32_with_padding() {
        let mut bytes = [0u8; 32];
        bytes[..4].copy_from_slice(b"name");
        let ident = B256::from_slice(&bytes);
        let decoded = decode_ident32(ident).unwrap();
        assert_eq!(decoded, "name");
    }

    #[test]
    fn decode_ident32_full_length() {
        let bytes = [b'a'; 32];
        let ident = B256::from_slice(&bytes);
        let decoded = decode_ident32(ident).unwrap();
        assert_eq!(decoded.len(), 32);
    }
}
