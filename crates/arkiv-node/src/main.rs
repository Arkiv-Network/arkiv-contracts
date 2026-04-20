mod decode;
mod exex;

use arkiv_store::LoggingStore;
use futures::future;
use reth::cli::Cli;
use reth_node_ethereum::EthereumNode;
use std::sync::Arc;

fn main() -> eyre::Result<()> {
    Cli::parse_args().run(|builder, _| async move {
        let store = Arc::new(LoggingStore::new());

        let handle = builder
            .node(EthereumNode::default())
            .install_exex("arkiv-exex", move |ctx| {
                let store = store.clone();
                future::ok(exex::arkiv_exex(ctx, store))
            })
            .launch()
            .await?;

        handle.wait_for_node_exit().await
    })
}
