use alloy_consensus::{BlockHeader, Transaction};
use alloy_primitives::Log;
use arkiv_bindings::ENTITY_REGISTRY_ADDRESS;
use arkiv_store::{RegistryBlock, RegistryTransaction, Storage};
use eyre::Result;
use futures_util::TryStreamExt;
use reth::builder::NodeTypes;
use reth::primitives::EthPrimitives;
use reth_exex::{ExExContext, ExExEvent};
use reth_node_api::FullNodeComponents;
use std::sync::Arc;
use tracing::info;

/// Run the Arkiv ExEx.
///
/// Filters each block for transactions targeting the EntityRegistry,
/// extracts raw calldata + logs, and forwards to the Storage backend.
pub async fn arkiv_exex<
    Node: FullNodeComponents<Types: NodeTypes<Primitives = EthPrimitives>>,
>(
    mut ctx: ExExContext<Node>,
    store: Arc<dyn Storage>,
) -> Result<()> {
    info!("arkiv-exex starting");

    while let Some(notification) = ctx.notifications.try_next().await? {
        // 1. Revert old blocks if present (ChainReverted or ChainReorged)
        if let Some(reverted) = notification.reverted_chain() {
            let block_numbers: Vec<u64> =
                reverted.blocks_iter().map(|b| b.header().number()).collect();
            for &bn in block_numbers.iter().rev() {
                store.handle_revert(bn)?;
            }
        }

        // 2. Commit new blocks if present (ChainCommitted or ChainReorged)
        if let Some(committed) = notification.committed_chain() {
            for (block, receipts) in committed.blocks_and_receipts() {
                if let Some(registry_block) = extract_registry_block(block, receipts) {
                    store.handle_commit(&registry_block)?;
                }
            }
            ctx.events
                .send(ExExEvent::FinishedHeight(committed.tip().num_hash()))?;
        }
    }

    info!("arkiv-exex exiting");
    Ok(())
}

/// Extract EntityRegistry transactions from a block.
///
/// Returns `None` if no transactions target the registry address.
fn extract_registry_block(
    block: &reth::primitives::RecoveredBlock<reth_ethereum_primitives::Block>,
    receipts: &[reth_ethereum_primitives::Receipt],
) -> Option<RegistryBlock> {
    let mut transactions = Vec::new();

    for (tx, receipt) in block.body().transactions().zip(receipts.iter()) {
        if tx.to() != Some(ENTITY_REGISTRY_ADDRESS) {
            continue;
        }

        let logs: Vec<Log> = receipt
            .logs
            .iter()
            .filter(|log| log.address == ENTITY_REGISTRY_ADDRESS)
            .cloned()
            .collect();

        transactions.push(RegistryTransaction {
            tx_hash: *tx.tx_hash(),
            calldata: tx.input().clone(),
            logs,
            success: receipt.success,
        });
    }

    if transactions.is_empty() {
        return None;
    }

    Some(RegistryBlock {
        block_number: block.header().number(),
        transactions,
    })
}
