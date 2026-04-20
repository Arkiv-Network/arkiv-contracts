pub mod types;

use eyre::Result;
use types::DecodedOperation;

/// Storage backend for the Arkiv ExEx indexer.
///
/// Implementations receive decoded operations from the ExEx notification
/// handler. The trait is intentionally minimal so that any database backend
/// (SQLite, PostgreSQL, in-memory, etc.) can be plugged in.
pub trait Storage: Send + Sync + 'static {
    /// Process a committed block's decoded operations.
    fn handle_commit(&self, block_number: u64, operations: &[DecodedOperation]) -> Result<()>;

    /// Revert all state changes from the given block (reorg handling).
    fn handle_revert(&self, block_number: u64) -> Result<()>;
}

/// A [`Storage`] implementation that logs every decoded operation via `tracing`.
///
/// This is the MVP backend — it proves the ExEx is correctly decoding
/// calldata and events without requiring any database infrastructure.
pub struct LoggingStore;

impl LoggingStore {
    pub fn new() -> Self {
        Self
    }
}

impl Storage for LoggingStore {
    fn handle_commit(&self, block_number: u64, operations: &[DecodedOperation]) -> Result<()> {
        if operations.is_empty() {
            return Ok(());
        }

        tracing::info!(
            block = block_number,
            count = operations.len(),
            "processing committed block"
        );

        for op in operations {
            tracing::info!(
                block = op.block_number,
                tx = %op.tx_hash,
                op_type = types::op_type_name(op.op_type),
                entity_key = %op.entity_key,
                owner = %op.owner,
                expires_at = op.expires_at,
                entity_hash = %op.entity_hash,
                has_content = op.entity.is_some(),
                "entity operation"
            );

            if let Some(entity) = &op.entity {
                tracing::debug!(
                    entity_key = %entity.entity_key,
                    content_type = entity.content_type.as_deref().unwrap_or(""),
                    payload_len = entity.payload.as_ref().map_or(0, |p| p.len()),
                    attribute_count = entity.attributes.len(),
                    "entity content"
                );
            }
        }

        Ok(())
    }

    fn handle_revert(&self, block_number: u64) -> Result<()> {
        tracing::warn!(block = block_number, "reverting block");
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy_primitives::{Address, B256};
    use types::DecodedOperation;

    #[test]
    fn logging_store_handles_empty_commit() {
        let store = LoggingStore::new();
        store.handle_commit(1, &[]).unwrap();
    }

    #[test]
    fn logging_store_handles_operations() {
        let store = LoggingStore::new();
        let ops = vec![DecodedOperation {
            block_number: 100,
            tx_hash: B256::ZERO,
            op_type: 1,
            entity_key: B256::repeat_byte(0x01),
            owner: Address::repeat_byte(0xAA),
            expires_at: 500,
            entity_hash: B256::repeat_byte(0x02),
            entity: None,
        }];
        store.handle_commit(100, &ops).unwrap();
    }

    #[test]
    fn logging_store_handles_revert() {
        let store = LoggingStore::new();
        store.handle_revert(50).unwrap();
    }
}
