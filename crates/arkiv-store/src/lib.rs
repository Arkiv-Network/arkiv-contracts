pub mod decode;
pub mod types;

use alloy_primitives::{Bytes, Log, B256};
use arkiv_bindings::ENTITY_REGISTRY_ADDRESS;
use eyre::Result;

/// A raw EntityRegistry transaction extracted by the ExEx.
pub struct RegistryTransaction {
    pub tx_hash: B256,
    /// Raw calldata (tx.input).
    pub calldata: Bytes,
    /// Receipt logs filtered to the registry address.
    pub logs: Vec<Log>,
    /// Whether the transaction succeeded.
    pub success: bool,
}

/// A block containing at least one EntityRegistry transaction.
pub struct RegistryBlock {
    pub block_number: u64,
    pub transactions: Vec<RegistryTransaction>,
}

/// Storage backend for the Arkiv ExEx.
///
/// The ExEx filters transactions targeting the EntityRegistry and passes
/// raw calldata + logs to the store. Each implementation decides how much
/// decoding to do:
/// - `LoggingStore` fully decodes for debugging
/// - A JSON-RPC store would forward raw data to an external service
pub trait Storage: Send + Sync + 'static {
    /// Process a block's EntityRegistry transactions.
    fn handle_commit(&self, block: &RegistryBlock) -> Result<()>;

    /// Revert state changes from the given block (reorg handling).
    fn handle_revert(&self, block_number: u64) -> Result<()>;
}

/// A [`Storage`] implementation that decodes and logs every operation via `tracing`.
pub struct LoggingStore;

impl LoggingStore {
    pub fn new() -> Self {
        Self
    }
}

impl Storage for LoggingStore {
    fn handle_commit(&self, block: &RegistryBlock) -> Result<()> {
        tracing::info!(
            block = block.block_number,
            tx_count = block.transactions.len(),
            "processing registry block"
        );

        for tx in &block.transactions {
            match decode::decode_registry_transaction(
                Some(ENTITY_REGISTRY_ADDRESS),
                &tx.calldata,
                tx.tx_hash,
                tx.success,
                &tx.logs,
                block.block_number,
            ) {
                Ok(ops) => {
                    for op in &ops {
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
                                payload_len = entity.payload.as_ref().map_or(0, |p: &alloy_primitives::Bytes| p.len()),
                                attribute_count = entity.attributes.len(),
                                "entity content"
                            );
                        }
                    }
                }
                Err(e) => {
                    tracing::error!(
                        tx = %tx.tx_hash,
                        block = block.block_number,
                        error = %e,
                        "failed to decode registry transaction"
                    );
                }
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

    #[test]
    fn logging_store_handles_empty_block() {
        let store = LoggingStore::new();
        let block = RegistryBlock {
            block_number: 1,
            transactions: vec![],
        };
        store.handle_commit(&block).unwrap();
    }

    #[test]
    fn logging_store_handles_revert() {
        let store = LoggingStore::new();
        store.handle_revert(50).unwrap();
    }
}
