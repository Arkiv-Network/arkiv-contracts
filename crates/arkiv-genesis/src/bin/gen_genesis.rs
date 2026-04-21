use arkiv_genesis::{generate_genesis, GenesisConfig};

fn main() -> eyre::Result<()> {
    let config = GenesisConfig::default();
    let genesis = generate_genesis(&config)?;

    let json = serde_json::to_string_pretty(&genesis)?;
    std::fs::write("genesis.json", &json)?;

    eprintln!("Wrote genesis.json");
    eprintln!("  EntityRegistry at {}", arkiv_genesis::ENTITY_REGISTRY_ADDRESS);
    eprintln!("  Chain ID: {}", config.chain_id);
    eprintln!("  Prefunded accounts: {}", config.prefunded_accounts.len());

    Ok(())
}
