mod decode;
mod exex;

use arkiv_genesis::{generate_genesis, GenesisConfig};
use arkiv_store::LoggingStore;
use futures::future;
use reth::chainspec::ChainSpec;
use reth::cli::Cli;
use reth_node_ethereum::EthereumNode;
use std::sync::Arc;

fn main() -> eyre::Result<()> {
    Cli::parse_args().run(|mut builder, _| async move {
        // Generate chain spec from arkiv-genesis with EntityRegistry predeployed.
        // This overrides whatever --chain was passed on the CLI.
        let config = GenesisConfig::default();
        let genesis = generate_genesis(&config)?;
        let chain_spec = Arc::new(ChainSpec::from(genesis));
        builder.config_mut().chain = chain_spec;

        let store = Arc::new(LoggingStore::new());

        let handle = builder
            .node(EthereumNode::default())
            .install_exex("arkiv-exex", move |ctx| {
                let store = store.clone();
                future::ok(exex::arkiv_exex(ctx, store))
            })
            .launch_with_debug_capabilities()
            .await?;

        handle.wait_for_node_exit().await
    })
}
