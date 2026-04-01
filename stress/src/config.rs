use alloy::primitives::Address;
use clap::{Parser, ValueEnum};
use std::str::FromStr;

/// Known contract address (deployer=0xf39F...2266, nonce=0)
pub const DEFAULT_CONTRACT: &str = "0x5FbDB2315678afecb367f032d93F642f64180aa3";
pub const DEFAULT_RPC_URL: &str = "http://127.0.0.1:8545";

/// Test mnemonic for generating stress test wallets (also used by Anvil/Hardhat)
pub const TEST_MNEMONIC: &str =
    "test test test test test test test test test test test junk";

#[derive(Debug, Clone, ValueEnum)]
pub enum Profile {
    /// CREATE with empty payload, 0 attributes, 1 op per tx
    CreateMinimal,
    /// CREATE with 1KB payload, 5 UINT attributes, 1 op per tx
    CreateSmall,
    /// CREATE with empty payload, 0 attributes, batched N ops per tx
    CreateBatched,
    /// Seed CREATEs then UPDATE with 1KB payload, 5 UINT attributes
    Update,
    /// Seed CREATEs then EXTEND
    Extend,
    /// Mixed workload: CREATE, UPDATE, EXTEND, DELETE
    Mixed,
}

impl Profile {
    /// Theoretical ops/sec from src/throughput.md (60M gas, 2s blocks)
    pub fn theoretical_ops_per_sec(&self) -> f64 {
        match self {
            Profile::CreateMinimal => 400.0,
            Profile::CreateSmall => 309.0,
            Profile::CreateBatched => 400.0, // same per-op cost, better amortization
            Profile::Update => 750.0,
            Profile::Extend => 2000.0,
            Profile::Mixed => 500.0, // estimated blend
        }
    }

    /// Whether this profile needs a seed phase (pre-existing entities)
    pub fn needs_seed(&self) -> bool {
        matches!(self, Profile::Update | Profile::Extend | Profile::Mixed)
    }
}

#[derive(Debug, Parser)]
#[command(name = "arkiv-stress", about = "EntityRegistry throughput stress test")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Parser)]
pub enum Command {
    /// Run a stress test against a reth node
    Run(RunArgs),
}

#[derive(Debug, Parser)]
pub struct RunArgs {
    /// Workload profile
    #[arg(long, value_enum, default_value = "create-minimal")]
    pub profile: Profile,

    /// Approximate test duration in seconds
    #[arg(long, default_value = "30")]
    pub duration: u64,

    /// Number of sender accounts
    #[arg(long, default_value = "10")]
    pub accounts: u32,

    /// Operations per execute() call (for batched profiles)
    #[arg(long, default_value = "1")]
    pub batch_size: u32,

    /// Max concurrent in-flight tx submissions
    #[arg(long, default_value = "50")]
    pub concurrency: usize,

    /// JSON-RPC endpoint
    #[arg(long, default_value = DEFAULT_RPC_URL)]
    pub rpc_url: String,

    /// EntityRegistry contract address
    #[arg(long, default_value = DEFAULT_CONTRACT)]
    pub contract: String,

    /// ETH to fund each test account (in wei)
    #[arg(long, default_value = "10000000000000000000")]
    pub eth_per_account: String,

    /// Output format
    #[arg(long, value_enum, default_value = "table")]
    pub output: OutputFormat,
}

#[derive(Debug, Clone, ValueEnum)]
pub enum OutputFormat {
    Table,
    Json,
}

impl RunArgs {
    pub fn contract_address(&self) -> eyre::Result<Address> {
        Ok(Address::from_str(&self.contract)?)
    }
}
