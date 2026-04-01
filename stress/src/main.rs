mod abi;

use std::io::Write;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

use alloy::{
    network::{EthereumWallet, TransactionBuilder},
    primitives::{Address, Bytes, FixedBytes, U256, keccak256},
    providers::{Provider, ProviderBuilder, SendableTx},
    signers::local::{coins_bip39::English, MnemonicBuilder},
    sol_types::SolCall,
};
use clap::Parser;
use eyre::Result;

use abi::EntityRegistry;

const MNEMONIC: &str = "test test test test test test test test test test test junk";
const TX_SIZE_LIMIT: usize = 131072;
const TX_ENVELOPE_OVERHEAD: usize = 256;

#[derive(Parser)]
#[command(name = "arkiv-stress", about = "EntityRegistry file upload throughput test")]
struct Cli {
    /// JSON-RPC endpoint
    #[arg(long, default_value = "http://127.0.0.1:8545")]
    rpc_url: String,

    /// File sizes to test in KB (comma-separated)
    #[arg(long, default_value = "1,10,100,1000,10000", value_delimiter = ',')]
    sizes: Vec<u64>,

    /// L2 execution gas price in gwei (fetched from Optimism if omitted)
    #[arg(long)]
    l2_gas_price_gwei: Option<f64>,

    /// L1 data availability cost per calldata byte in gwei
    #[arg(long)]
    l1_data_price_gwei: Option<f64>,

    /// ETH price in USD (fetched from CoinGecko if omitted)
    #[arg(long)]
    eth_price_usd: Option<f64>,

    /// Optimism RPC for fetching L2 gas price
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
    chunks: usize,
    succeeded: u64,
    failed: u64,
    total_calldata: usize,
    total_gas: u64,
}

impl SizeResult {
    fn l2_cost_eth(&self, l2_gwei: f64) -> f64 {
        self.total_gas as f64 * l2_gwei * 1e-9
    }
    fn l1_cost_eth(&self, l1_gwei: f64) -> f64 {
        self.total_calldata as f64 * l1_gwei * 1e-9
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

    let prices = fetch_prices(&cli).await?;
    println!("Prices:");
    println!("  L2 gas price:  {:.4} gwei", prices.l2_gas_price_gwei);
    println!("  L1 data price: {:.2} gwei/byte", prices.l1_data_price_gwei);
    println!("  ETH/USD:       ${:.0}", prices.eth_price_usd);
    println!();

    let provider = ProviderBuilder::new().connect_http(rpc_url.clone());
    let chain_id = provider.get_chain_id().await?;
    println!("Chain {chain_id} at {}", cli.rpc_url);

    let dev_wallet = MnemonicBuilder::<English>::default()
        .phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/0")?.build()?;
    let user_addr: Address = MnemonicBuilder::<English>::default()
        .phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/1")?.build()?.address();

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

    // Deploy
    println!("Deploying EntityRegistry...");
    let contract_addr = deploy_registry(&rpc_url).await?;
    println!("  Deployed at: {contract_addr}");

    let max_payload = compute_max_payload();
    println!("  Max payload per chunk: {} KB (tx limit {} KB)", max_payload / 1024, TX_SIZE_LIMIT / 1024);
    println!();

    let user_wallet = MnemonicBuilder::<English>::default()
        .phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/1")?.build()?;

    let mut results = Vec::new();
    for &size_kb in &cli.sizes {
        let r = run_size(&provider, &user_wallet, &rpc_url, contract_addr, size_kb, max_payload).await?;
        results.push(r);
    }

    print_report(&results, &prices);
    Ok(())
}

fn compute_max_payload() -> usize {
    let sample = EntityRegistry::executeCall {
        ops: vec![EntityRegistry::Op {
            opType: 0,
            entityKey: FixedBytes::ZERO,
            payload: Bytes::new(),
            contentType: "application/octet-stream".to_string(),
            attributes: chunk_attributes(FixedBytes::ZERO, 0, 1),
            expiresAt: u32::MAX,
        }],
    };
    let overhead = SolCall::abi_encode(&sample).len();
    TX_SIZE_LIMIT - TX_ENVELOPE_OVERHEAD - overhead
}

fn chunk_attributes(
    file_hash: FixedBytes<32>,
    chunk_idx: u64,
    chunk_total: u64,
) -> Vec<EntityRegistry::Attribute> {
    vec![
        uint_attr("chunk_idx", chunk_idx),
        uint_attr("chunk_total", chunk_total),
        entity_key_attr("file_hash", file_hash),
    ]
}

fn uint_attr(name: &str, value: u64) -> EntityRegistry::Attribute {
    EntityRegistry::Attribute {
        name: short_string(name),
        valueType: 0,
        fixedValue: FixedBytes::from(U256::from(value).to_be_bytes::<32>()),
        stringValue: String::new(),
    }
}

fn entity_key_attr(name: &str, value: FixedBytes<32>) -> EntityRegistry::Attribute {
    EntityRegistry::Attribute {
        name: short_string(name),
        valueType: 2,
        fixedValue: value,
        stringValue: String::new(),
    }
}

fn short_string(s: &str) -> FixedBytes<32> {
    let bytes = s.as_bytes();
    assert!(bytes.len() <= 31, "ShortString too long: {s}");
    let mut buf = [0u8; 32];
    buf[..bytes.len()].copy_from_slice(bytes);
    buf[31] = (bytes.len() * 2) as u8;
    FixedBytes::from(buf)
}

async fn deploy_registry(rpc_url: &alloy::transports::http::reqwest::Url) -> Result<Address> {
    let deployer = MnemonicBuilder::<English>::default()
        .phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/0")?.build()?;
    let provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(deployer))
        .connect_http(rpc_url.clone());

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

async fn run_size<P: Provider>(
    reader: &P,
    user_wallet: &alloy::signers::local::PrivateKeySigner,
    rpc_url: &alloy::transports::http::reqwest::Url,
    contract: Address,
    size_kb: u64,
    max_payload: usize,
) -> Result<SizeResult> {
    let file_bytes = (size_kb * 1024) as usize;
    let file_data = vec![0xABu8; file_bytes];
    let file_hash = keccak256(&file_data);

    let chunk_count = if file_bytes == 0 { 1 } else { (file_bytes + max_payload - 1) / max_payload };
    let expires_at = reader.get_block_number().await? as u32 + 1_000_000;

    let wallet_addr = user_wallet.address();
    let mut nonce = reader.get_transaction_count(wallet_addr).await?;

    // Build a wallet provider for signing
    let signer_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(user_wallet.clone()))
        .connect_http(rpc_url.clone());

    // Build and sign all chunk txs upfront
    let mut signed_txs: Vec<Bytes> = Vec::with_capacity(chunk_count);
    let mut total_calldata: usize = 0;

    for i in 0..chunk_count {
        let start = i * max_payload;
        let end = (start + max_payload).min(file_bytes);

        let op = EntityRegistry::Op {
            opType: 0,
            entityKey: FixedBytes::ZERO,
            payload: Bytes::from(file_data[start..end].to_vec()),
            contentType: "application/octet-stream".to_string(),
            attributes: chunk_attributes(file_hash, i as u64, chunk_count as u64),
            expiresAt: expires_at,
        };

        let calldata = SolCall::abi_encode(&EntityRegistry::executeCall { ops: vec![op] });
        total_calldata += calldata.len();

        let tx_for_estimate = alloy::rpc::types::TransactionRequest::default()
            .to(contract)
            .input(alloy::rpc::types::TransactionInput {
                input: Some(Bytes::from(calldata.clone())),
                data: None,
            });

        // Use eth_estimateGas for accurate limit, with 20% headroom
        let estimated = reader.estimate_gas(tx_for_estimate).await?;
        let gas_limit = estimated * 120 / 100;

        let tx = alloy::rpc::types::TransactionRequest::default()
            .to(contract)
            .input(alloy::rpc::types::TransactionInput {
                input: Some(calldata.into()),
                data: None,
            })
            .nonce(nonce)
            .gas_limit(gas_limit)
            .max_fee_per_gas(20_000_000_000)
            .max_priority_fee_per_gas(1_000_000_000);

        // Fill + sign, extract raw encoded bytes
        let sendable = signer_provider.fill(tx).await?;
        let raw = match sendable {
            SendableTx::Envelope(env) => {
                use alloy::eips::Encodable2718;
                Bytes::from(env.encoded_2718())
            }
            _ => return Err(eyre::eyre!("unexpected sendable tx type")),
        };

        signed_txs.push(raw);
        nonce += 1;
    }

    println!(
        "  {:>6} KB  {} chunk{}  ({} calldata)",
        size_kb, chunk_count,
        if chunk_count == 1 { "" } else { "s" },
        format_bytes(total_calldata),
    );

    // Blast all signed txs into mempool
    let plain_provider = ProviderBuilder::new().connect_http(rpc_url.clone());

    let mined = Arc::new(AtomicU64::new(0));
    let gas_total = Arc::new(AtomicU64::new(0));
    let errors = Arc::new(AtomicU64::new(0));
    let start = Instant::now();

    // Fire all at once — mempool handles ordering via nonces
    let mut tx_hashes = Vec::with_capacity(chunk_count);
    for raw in &signed_txs {
        match plain_provider.send_raw_transaction(raw).await {
            Ok(pending) => tx_hashes.push(Some(pending)),
            Err(e) => {
                eprintln!("    send error: {e}");
                errors.fetch_add(1, Ordering::Relaxed);
                tx_hashes.push(None);
            }
        }
    }

    let sent = tx_hashes.iter().filter(|h| h.is_some()).count();
    if chunk_count > 1 {
        print!("           {sent}/{chunk_count} sent, waiting for receipts...");
        let _ = std::io::stdout().flush();
    }

    // Collect all receipts in parallel
    let mut receipt_handles = Vec::new();
    for pending_opt in tx_hashes {
        let mined = mined.clone();
        let gas_total = gas_total.clone();
        let errors = errors.clone();
        let chunk_count = chunk_count;

        receipt_handles.push(tokio::spawn(async move {
            let Some(pending) = pending_opt else { return };
            match pending.get_receipt().await {
                Ok(receipt) => {
                    gas_total.fetch_add(receipt.gas_used as u64, Ordering::Relaxed);
                    let done = mined.fetch_add(1, Ordering::Relaxed) + 1;
                    if chunk_count > 1 && (done % 10 == 0 || done == chunk_count as u64) {
                        print!("\r           {done}/{chunk_count} mined              ");
                        let _ = std::io::stdout().flush();
                    }
                }
                Err(e) => {
                    errors.fetch_add(1, Ordering::Relaxed);
                    eprintln!("\n    receipt error: {e}");
                }
            }
        }));
    }

    for h in receipt_handles {
        let _ = h.await;
    }

    let elapsed = start.elapsed().as_secs_f64();
    let total_gas = gas_total.load(Ordering::Relaxed);
    let succeeded = mined.load(Ordering::Relaxed);
    let failed = errors.load(Ordering::Relaxed);

    if chunk_count > 1 { print!("\r"); }
    println!(
        "           {succeeded}/{chunk_count} mined, {} gas, {:.1}s{}",
        format_gas(total_gas), elapsed,
        if failed > 0 { format!(" ({failed} failed)") } else { String::new() },
    );

    Ok(SizeResult {
        size_kb,
        chunks: chunk_count,
        succeeded,
        failed,
        total_calldata,
        total_gas,
    })
}

// --- Price fetching ---

async fn fetch_prices(cli: &Cli) -> Result<Prices> {
    let client = alloy::transports::http::reqwest::Client::new();

    let eth_price_usd = if let Some(p) = cli.eth_price_usd {
        p
    } else {
        match client
            .get("https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd")
            .send().await
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

    let l1_data_price_gwei = cli.l1_data_price_gwei.unwrap_or(5.0);

    Ok(Prices { l2_gas_price_gwei, l1_data_price_gwei, eth_price_usd })
}

async fn fetch_op_gas_price(
    client: &alloy::transports::http::reqwest::Client,
    op_rpc_url: &str,
) -> Result<f64> {
    let body = serde_json::json!({
        "jsonrpc": "2.0", "method": "eth_gasPrice", "params": [], "id": 1
    });
    let resp = client.post(op_rpc_url).json(&body).send().await?;
    let json: serde_json::Value = resp.json().await?;
    let hex = json["result"].as_str().ok_or_else(|| eyre::eyre!("bad response"))?;
    let wei = u128::from_str_radix(hex.trim_start_matches("0x"), 16)?;
    Ok(wei as f64 / 1e9)
}

// --- Reporting ---

fn print_report(results: &[SizeResult], prices: &Prices) {
    println!();
    println!("EntityRegistry File Upload Cost (Optimism L2 model)");
    println!("===================================================");
    println!(
        "  L2 gas: {:.4} gwei  |  L1 data: {:.2} gwei/byte  |  ETH: ${:.0}",
        prices.l2_gas_price_gwei, prices.l1_data_price_gwei, prices.eth_price_usd
    );
    println!("  Tx size limit: {} KB  |  Chunk attrs: file_hash, chunk_idx, chunk_total",
        TX_SIZE_LIMIT / 1024);
    println!();

    println!(
        "  {:>8}  {:>6}  {:>5}  {:>10}  {:>10}  {:>10}  {:>10}  {:>10}  {:>8}",
        "File", "Chunks", "OK", "Calldata", "Gas", "L2 Cost", "L1 Cost", "Total", "USD"
    );
    println!(
        "  {:>8}  {:>6}  {:>5}  {:>10}  {:>10}  {:>10}  {:>10}  {:>10}  {:>8}",
        "────────", "──────", "─────", "──────────", "──────────", "──────────", "──────────", "──────────", "────────"
    );

    for r in results {
        let status = if r.failed > 0 {
            format!("{}/{}", r.succeeded, r.chunks)
        } else {
            format!("{}", r.succeeded)
        };

        println!(
            "  {:>5} KB  {:>6}  {:>5}  {:>10}  {:>10}  {:>10}  {:>10}  {:>10}  {:>8}",
            r.size_kb,
            r.chunks,
            status,
            format_bytes(r.total_calldata),
            format_gas(r.total_gas),
            format_eth(r.l2_cost_eth(prices.l2_gas_price_gwei)),
            format_eth(r.l1_cost_eth(prices.l1_data_price_gwei)),
            format_eth(r.total_eth(prices)),
            format_usd(r.total_usd(prices)),
        );
    }

    println!();
    println!("  Cost breakdown per file:");
    for r in results {
        let l2 = r.l2_cost_eth(prices.l2_gas_price_gwei);
        let l1 = r.l1_cost_eth(prices.l1_data_price_gwei);
        let total = r.total_eth(prices);
        let l1_pct = if total > 0.0 { l1 / total * 100.0 } else { 0.0 };
        let status = if r.failed > 0 { format!(" [{} failed]", r.failed) } else { String::new() };
        println!(
            "    {:>5} KB ({} chunk{}): {} = L2 {} + L1 {} ({:.0}% L1 data){status}",
            r.size_kb, r.chunks,
            if r.chunks == 1 { "" } else { "s" },
            format_usd(r.total_usd(prices)),
            format_eth(l2), format_eth(l1), l1_pct,
        );
    }
    println!();
}

// --- Formatting ---

fn format_gas(gas: u64) -> String {
    if gas >= 1_000_000 { format!("{:.1}M", gas as f64 / 1e6) }
    else if gas >= 1_000 { format!("{:.1}K", gas as f64 / 1e3) }
    else { format!("{gas}") }
}

fn format_bytes(b: usize) -> String {
    if b >= 1_048_576 { format!("{:.1} MB", b as f64 / 1_048_576.0) }
    else if b >= 1024 { format!("{:.1} KB", b as f64 / 1024.0) }
    else { format!("{b} B") }
}

fn format_eth(eth: f64) -> String {
    if eth == 0.0 { "0".to_string() }
    else if eth < 1e-9 { format!("{:.1e}", eth) }
    else if eth < 1e-6 { format!("{:.4}µ", eth * 1e6) }
    else if eth < 1e-3 { format!("{:.4}m", eth * 1e3) }
    else { format!("{:.6}", eth) }
}

fn format_usd(usd: f64) -> String {
    if usd < 0.001 { format!("${:.4}", usd) }
    else if usd < 1.0 { format!("${:.3}", usd) }
    else { format!("${:.2}", usd) }
}
