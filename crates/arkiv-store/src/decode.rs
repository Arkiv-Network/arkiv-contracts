use alloy_primitives::{Address, B256};
use alloy_sol_types::{SolCall, SolEvent};
use arkiv_bindings::{
    executeCall, Attribute as AbiAttribute, Mime128, Operation as AbiOperation,
    IEntityRegistry::EntityOperation as AbiEntityOperation, ENTITY_REGISTRY_ADDRESS,
    OP_CREATE, OP_UPDATE,
};
use crate::types::{DecodedAttribute, DecodedOperation, EntityRecord};
use eyre::{bail, Result};

/// Decode calldata + event logs from a transaction.
///
/// For CREATE/UPDATE operations, decodes both calldata (for payload/attributes)
/// and logs (for entityKey/entityHash). For other operations, logs alone suffice.
pub fn decode_registry_transaction(
    tx_to: Option<Address>,
    tx_input: &[u8],
    tx_hash: B256,
    receipt_success: bool,
    receipt_logs: &[alloy_primitives::Log],
    block_number: u64,
) -> Result<Vec<DecodedOperation>> {
    // Only interested in calls to the EntityRegistry
    if tx_to != Some(ENTITY_REGISTRY_ADDRESS) {
        return Ok(Vec::new());
    }

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
        if log.address != ENTITY_REGISTRY_ADDRESS {
            continue;
        }
        match AbiEntityOperation::decode_log_data(&log.data) {
            Ok(evt) => events.push(evt),
            Err(_) => {
                // Log doesn't match EntityOperation signature, skip
                continue;
            }
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
        creator: Address::ZERO, // Set by ExEx from event
        owner: Address::ZERO,   // Set by ExEx from event
        created_at: 0,          // Set by ExEx from event
        updated_at: 0,          // Set by ExEx from event
        expires_at: op.expiresAt,
        core_hash: B256::ZERO,  // Computed by ExEx
        entity_hash: B256::ZERO, // Set by ExEx from event
        payload: Some(op.payload.clone()),
        content_type,
        attributes,
    })
}

/// Decode a Mime128 (4 x bytes32) to a string.
fn decode_mime128(mime: &Mime128) -> Option<String> {
    // Concatenate the 4 bytes32 values and find the first null byte
    let mut bytes = Vec::with_capacity(128);
    for b32 in &mime.data {
        bytes.extend_from_slice(b32.as_ref());
    }

    // Find null terminator
    if let Some(null_pos) = bytes.iter().position(|b| *b == 0) {
        bytes.truncate(null_pos);
    }

    String::from_utf8(bytes).ok()
}

/// Decode an Attribute from calldata.
fn decode_attribute(attr: &AbiAttribute) -> Result<DecodedAttribute> {
    // Decode the name (Ident32 = bytes32)
    let name = decode_ident32(attr.name)?;

    Ok(DecodedAttribute {
        name,
        value_type: attr.valueType,
        raw_value: attr.value,
    })
}

/// Decode an Ident32 (bytes32 with left-aligned ASCII) to a string.
fn decode_ident32(ident: B256) -> Result<String> {
    let bytes: &[u8] = ident.as_ref();
    // Find the first null byte (padding)
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
        let mut bytes = [b'a'; 32];
        let ident = B256::from_slice(&bytes);
        let decoded = decode_ident32(ident).unwrap();
        assert_eq!(decoded.len(), 32);
    }
}
