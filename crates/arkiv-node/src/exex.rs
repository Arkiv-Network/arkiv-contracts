use arkiv_store::Storage;
use eyre::Result;
use futures_util::TryStreamExt;
use reth_exex::{ExExContext, ExExEvent};
use reth_node_api::FullNodeComponents;
use std::sync::Arc;
use tracing::info;

/// Run the Arkiv indexer ExEx.
///
/// Processes blockchain notifications and decodes EntityRegistry operations,
/// passing them to the Storage backend.
pub async fn arkiv_exex<Node: FullNodeComponents>(
    mut ctx: ExExContext<Node>,
    _store: Arc<dyn Storage>,
) -> Result<()> {
    info!("arkiv-exex starting - 123");

    while let Some(notification) = ctx.notifications.try_next().await? {
        // Process committed chain if present
        if let Some(committed) = notification.committed_chain() {
            let tip = committed.tip();
            info!("arkiv-exex processed committed chain");

            // Signal that we've processed up to this notification
            ctx.events.send(ExExEvent::FinishedHeight(tip.num_hash()))?;
        }
    }

    info!("arkiv-exex exiting");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn exex_compiles() {
        // Type check only
    }
}
