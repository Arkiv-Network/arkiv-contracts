mod abi;

use std::time::Instant;

use alloy::{
    network::{EthereumWallet, TransactionBuilder},
    primitives::{Address, Bytes, FixedBytes, U256},
    providers::{Provider, ProviderBuilder},
    signers::local::{coins_bip39::English, MnemonicBuilder},
    sol_types::SolCall,
};
use clap::Parser;
use eyre::Result;

use abi::EntityRegistry;

const MNEMONIC: &str = "test test test test test test test test test test test junk";

#[derive(Parser)]
#[command(name = "arkiv-stress", about = "EntityRegistry file upload throughput test")]
struct Cli {
    /// JSON-RPC endpoint
    #[arg(long, default_value = "http://127.0.0.1:8545")]
    rpc_url: String,

    /// File sizes to test in KB (comma-separated)
    #[arg(long, default_value = "1,10,100", value_delimiter = ',')]
    sizes: Vec<u64>,

    // --- Optimism L2 cost model (overrides live data if set) ---

    /// L2 execution gas price in gwei (fetched from Optimism if omitted)
    #[arg(long)]
    l2_gas_price_gwei: Option<f64>,

    /// L1 data availability cost per calldata byte in gwei (default: 5)
    #[arg(long)]
    l1_data_price_gwei: Option<f64>,

    /// ETH price in USD (fetched from CoinGecko if omitted)
    #[arg(long)]
    eth_price_usd: Option<f64>,

    /// Optimism RPC for fetching L2 gas price (default: public endpoint)
    #[arg(long, default_value = "https://mainnet.optimism.io")]
    op_rpc_url: String,
}

struct Prices {
    l2_gas_price_gwei: f64,
    l1_data_price_gwei: f64,
    eth_price_usd: f64,
}

struct SizeResult {
    size_kb: u64,
    calldata_bytes: usize,
    avg_gas: u64,
}

impl SizeResult {
    fn l2_cost_eth(&self, l2_gwei: f64) -> f64 {
        self.avg_gas as f64 * l2_gwei * 1e-9
    }

    fn l1_cost_eth(&self, l1_gwei: f64) -> f64 {
        self.calldata_bytes as f64 * l1_gwei * 1e-9
    }

    fn total_eth(&self, p: &Prices) -> f64 {
        self.l2_cost_eth(p.l2_gas_price_gwei) + self.l1_cost_eth(p.l1_data_price_gwei)
    }

    fn total_usd(&self, p: &Prices) -> f64 {
        self.total_eth(p) * p.eth_price_usd
    }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let rpc_url: alloy::transports::http::reqwest::Url = cli.rpc_url.parse()?;

    // Fetch prices
    let prices = fetch_prices(&cli).await?;
    println!("Prices:");
    println!("  L2 gas price:  {:.4} gwei", prices.l2_gas_price_gwei);
    println!("  L1 data price: {:.2} gwei/byte", prices.l1_data_price_gwei);
    println!("  ETH/USD:       ${:.0}", prices.eth_price_usd);
    println!();

    // Connect
    let provider = ProviderBuilder::new().connect_http(rpc_url.clone());
    let chain_id = provider.get_chain_id().await?;
    println!("Chain {chain_id} at {}", cli.rpc_url);

    // Wallets
    let dev_wallet = MnemonicBuilder::<English>::default()
        .phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/0")?.build()?;
    let user_wallet = MnemonicBuilder::<English>::default()
        .phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/1")?.build()?;
    let user_addr: Address = user_wallet.address();

    // Fund user
    let balance = provider.get_balance(user_addr).await?;
    if balance < U256::from(100u64) * U256::from(10u64).pow(U256::from(18u64)) {
        println!("Funding user...");
        let dev_provider = ProviderBuilder::new()
            .wallet(EthereumWallet::from(dev_wallet))
            .connect_http(rpc_url.clone());
        let fund_tx = alloy::rpc::types::TransactionRequest::default()
            .to(user_addr)
            .value(U256::from(1000u64) * U256::from(10u64).pow(U256::from(18u64)));
        dev_provider.send_transaction(fund_tx).await?.watch().await?;
    }

    // Deploy EntityRegistry
    println!("Deploying EntityRegistry...");
    let contract_addr = deploy_registry(&rpc_url).await?;
    println!("  Deployed at: {contract_addr}");
    println!();

    // Run each size
    let user_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(user_wallet))
        .connect_http(rpc_url.clone());

    let mut results = Vec::new();
    for &size_kb in &cli.sizes {
        let r = run_size(&provider, &user_provider, contract_addr, size_kb).await?;
        results.push(r);
    }

    print_report(&results, &prices);
    Ok(())
}

async fn deploy_registry(rpc_url: &alloy::transports::http::reqwest::Url) -> Result<Address> {
    let deployer = MnemonicBuilder::<English>::default()
        .phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/0")?.build()?;
    let provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(deployer))
        .connect_http(rpc_url.clone());

    // Read compiled bytecode from forge artifact
    let artifact_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../out/EntityRegistry.sol/EntityRegistry.json");
    let artifact: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(&artifact_path)
            .map_err(|e| eyre::eyre!("Run `forge build` first: {e}"))?)?;
    let bytecode_hex = artifact["bytecode"]["object"]
        .as_str()
        .ok_or_else(|| eyre::eyre!("No bytecode in artifact"))?;
    let bytecode = alloy::hex::decode(bytecode_hex)?;

    let tx = alloy::rpc::types::TransactionRequest::default()
        .with_deploy_code(bytecode)
        .gas_limit(5_000_000);

    let receipt = provider.send_transaction(tx).await?.get_receipt().await?;
    receipt.contract_address
        .ok_or_else(|| eyre::eyre!("No contract address in receipt"))
}

async fn run_size<P: Provider, U: Provider>(
    reader: &P,
    sender: &U,
    contract: Address,
    size_kb: u64,
) -> Result<SizeResult> {
    let payload = vec![0xABu8; (size_kb * 1024) as usize];

    let op = EntityRegistry::Op {
        opType: 0,
        entityKey: FixedBytes::ZERO,
        payload: Bytes::from(payload),
        contentType: "application/octet-stream".to_string(),
        attributes: vec![],
        expiresAt: reader.get_block_number().await? as u32 + 1_000_000,
    };

    let calldata = SolCall::abi_encode(&EntityRegistry::executeCall { ops: vec![op] });
    let calldata_bytes = calldata.len();

    print!("  {:>6} KB  (calldata {} bytes) ... ", size_kb, calldata_bytes);
    use std::io::Write;
    let _ = std::io::stdout().flush();

    let tx = alloy::rpc::types::TransactionRequest::default()
        .to(contract)
        .input(alloy::rpc::types::TransactionInput {
            input: Some(calldata.into()),
            data: None,
        })
        .gas_limit(29_000_000);

    let start = Instant::now();
    let receipt = sender.send_transaction(tx).await?.get_receipt().await?;
    let duration_secs = start.elapsed().as_secs_f64();

    let gas_used = receipt.gas_used;
    println!("{} gas, {:.1}s", gas_used, duration_secs);

    Ok(SizeResult {
        size_kb,
        calldata_bytes,
        avg_gas: gas_used as u64,
    })
}

async fn fetch_prices(cli: &Cli) -> Result<Prices> {
    let client = alloy::transports::http::reqwest::Client::new();

    // ETH price from CoinGecko
    let eth_price_usd = if let Some(p) = cli.eth_price_usd {
        p
    } else {
        match client
            .get("https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd")
            .send()
            .await
        {
            Ok(resp) => {
                let body: serde_json::Value = resp.json().await.unwrap_or_default();
                body["ethereum"]["usd"].as_f64().unwrap_or(2000.0)
            }
            Err(_) => {
                eprintln!("  Could not fetch ETH price, using $2000");
                2000.0
            }
        }
    };

    // L2 gas price from Optimism RPC
    let l2_gas_price_gwei = if let Some(p) = cli.l2_gas_price_gwei {
        p
    } else {
        match fetch_op_gas_price(&client, &cli.op_rpc_url).await {
            Ok(p) => p,
            Err(_) => {
                eprintln!("  Could not fetch OP gas price, using 0.001 gwei");
                0.001
            }
        }
    };

    // L1 data price — no simple public API, use default or override
    let l1_data_price_gwei = cli.l1_data_price_gwei.unwrap_or(5.0);

    Ok(Prices { l2_gas_price_gwei, l1_data_price_gwei, eth_price_usd })
}

async fn fetch_op_gas_price(
    client: &alloy::transports::http::reqwest::Client,
    op_rpc_url: &str,
) -> Result<f64> {
    let body = serde_json::json!({
        "jsonrpc": "2.0",
        "method": "eth_gasPrice",
        "params": [],
        "id": 1
    });
    let resp = client.post(op_rpc_url).json(&body).send().await?;
    let json: serde_json::Value = resp.json().await?;
    let hex = json["result"].as_str().ok_or_else(|| eyre::eyre!("bad response"))?;
    let wei = u128::from_str_radix(hex.trim_start_matches("0x"), 16)?;
    Ok(wei as f64 / 1e9) // wei to gwei
}

fn print_report(results: &[SizeResult], prices: &Prices) {
    println!();
    println!("EntityRegistry File Upload Cost (Optimism L2 model)");
    println!("===================================================");
    println!(
        "  L2 gas: {:.4} gwei  |  L1 data: {:.2} gwei/byte  |  ETH: ${:.0}",
        prices.l2_gas_price_gwei, prices.l1_data_price_gwei, prices.eth_price_usd
    );
    println!();

    println!(
        "  {:>8}  {:>10}  {:>10}  {:>10}  {:>10}  {:>10}  {:>8}",
        "File", "Calldata", "Gas Used", "L2 Cost", "L1 Cost", "Total", "USD"
    );
    println!(
        "  {:>8}  {:>10}  {:>10}  {:>10}  {:>10}  {:>10}  {:>8}",
        "────────", "──────────", "──────────", "──────────", "──────────", "──────────", "────────"
    );

    for r in results {
        let l2 = r.l2_cost_eth(prices.l2_gas_price_gwei);
        let l1 = r.l1_cost_eth(prices.l1_data_price_gwei);
        let total = r.total_eth(prices);
        let usd = r.total_usd(prices);
        println!(
            "  {:>5} KB  {:>7} KB  {:>10}  {:>10}  {:>10}  {:>10}  {:>8}",
            r.size_kb,
            r.calldata_bytes / 1024,
            format_gas(r.avg_gas),
            format_eth(l2),
            format_eth(l1),
            format_eth(total),
            format_usd(usd),
        );
    }

    println!();
    println!("  Cost breakdown:");
    for r in results {
        let l2 = r.l2_cost_eth(prices.l2_gas_price_gwei);
        let l1 = r.l1_cost_eth(prices.l1_data_price_gwei);
        let total = r.total_eth(prices);
        let l1_pct = if total > 0.0 { l1 / total * 100.0 } else { 0.0 };
        println!(
            "    {:>5} KB: {} = L2 {} + L1 {} ({:.0}% L1 data)",
            r.size_kb,
            format_usd(r.total_usd(prices)),
            format_eth(l2),
            format_eth(l1),
            l1_pct,
        );
    }
    println!();
}

fn format_gas(gas: u64) -> String {
    if gas >= 1_000_000 {
        format!("{:.1}M", gas as f64 / 1_000_000.0)
    } else if gas >= 1_000 {
        format!("{:.1}K", gas as f64 / 1_000.0)
    } else {
        format!("{gas}")
    }
}

fn format_eth(eth: f64) -> String {
    if eth == 0.0 {
        "0".to_string()
    } else if eth < 1e-9 {
        format!("{:.1e}", eth)
    } else if eth < 1e-6 {
        format!("{:.4}µ", eth * 1e6)
    } else if eth < 1e-3 {
        format!("{:.4}m", eth * 1e3)
    } else {
        format!("{:.6}", eth)
    }
}

fn format_usd(usd: f64) -> String {
    if usd < 0.001 {
        format!("${:.4}", usd)
    } else if usd < 1.0 {
        format!("${:.3}", usd)
    } else {
        format!("${:.2}", usd)
    }
}
