mod abi;

use std::io::Write;
use std::time::Instant;

use alloy::{
    eips::Encodable2718,
    network::{EthereumWallet, TransactionBuilder},
    primitives::{Address, Bytes, FixedBytes, U256, keccak256},
    providers::{Provider, ProviderBuilder, SendableTx},
    signers::local::{coins_bip39::English, MnemonicBuilder, PrivateKeySigner},
    sol_types::SolCall,
};
use clap::Parser;
use eyre::Result;

use abi::EntityRegistry;

const MNEMONIC: &str = "test test test test test test test test test test test junk";
const TX_ENVELOPE_OVERHEAD: usize = 256;

#[derive(Parser)]
#[command(name = "arkiv-stress", about = "EntityRegistry file upload throughput test")]
struct Cli {
    /// JSON-RPC endpoint (start reth with stress/start-reth.sh)
    #[arg(long, default_value = "http://127.0.0.1:8545")]
    rpc_url: String,
    /// File sizes to test in KB (comma-separated)
    #[arg(long, default_value = "1,10,100,1000,10000", value_delimiter = ',')]
    sizes: Vec<u64>,
    /// Max transaction size in bytes
    /// Max transaction size in bytes (128KB = Ethereum default)
    #[arg(long, default_value_t = 131072)]
    tx_size_limit: usize,
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

struct ChunkReceipt {
    chunk_idx: usize,
    block_number: u64,
    tx_index: u64,
    gas_used: u64,
    base_fee: u64,
    calldata_bytes: usize,
    changeset_hash: FixedBytes<32>,
}

impl ChunkReceipt {
    fn l2_cost_eth(&self, l2_gwei: f64) -> f64 { self.gas_used as f64 * l2_gwei * 1e-9 }
    fn l1_cost_eth(&self, l1_gwei: f64) -> f64 { self.calldata_bytes as f64 * l1_gwei * 1e-9 }
}

struct SizeResult {
    size_kb: u64,
    chunks: Vec<ChunkReceipt>,
    failed: u64,
    total_calldata: usize,
}

impl SizeResult {
    fn total_gas(&self) -> u64 { self.chunks.iter().map(|c| c.gas_used).sum() }
    fn l2_cost_eth(&self, l2: f64) -> f64 { self.total_gas() as f64 * l2 * 1e-9 }
    fn l1_cost_eth(&self, l1: f64) -> f64 { self.total_calldata as f64 * l1 * 1e-9 }
    fn total_eth(&self, p: &Prices) -> f64 { self.l2_cost_eth(p.l2_gas_price_gwei) + self.l1_cost_eth(p.l1_data_price_gwei) }
    fn total_usd(&self, p: &Prices) -> f64 { self.total_eth(p) * p.eth_price_usd }
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    let rpc_url: alloy::transports::http::reqwest::Url = cli.rpc_url.parse()?;

    let prices = fetch_prices(cli.l2_gas_price_gwei, cli.l1_data_price_gwei, cli.eth_price_usd, &cli.op_rpc_url).await?;
    print_prices(&prices);

    let provider = ProviderBuilder::new().connect_http(rpc_url.clone());
    println!("Chain {} at {}", provider.get_chain_id().await?, cli.rpc_url);

    setup_user(&provider, &rpc_url).await?;
    let contract = deploy_registry(&rpc_url).await?;
    println!("  Deployed: {contract}");

    let gas_limit = get_block_gas_limit(&provider).await?;
    let max_payload = find_max_payload(&provider, contract, cli.tx_size_limit, gas_limit).await?;
    println!();

    let wallet = user_wallet()?;
    let mut results = Vec::new();
    for &kb in &cli.sizes {
        results.push(run_size(&provider, &wallet, &rpc_url, contract, kb, max_payload, gas_limit).await?);
    }

    print_report(&results, &prices);
    Ok(())
}

// =============================================================================
// Chain interaction
// =============================================================================

fn user_wallet() -> Result<PrivateKeySigner> {
    Ok(MnemonicBuilder::<English>::default()
        .phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/1")?.build()?)
}

async fn setup_user<P: Provider>(provider: &P, rpc_url: &alloy::transports::http::reqwest::Url) -> Result<()> {
    let user_addr: Address = user_wallet()?.address();
    let balance = provider.get_balance(user_addr).await?;
    let threshold = U256::from(100u64) * U256::from(10u64).pow(U256::from(18u64));
    if balance < threshold {
        let dev = MnemonicBuilder::<English>::default().phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/0")?.build()?;
        let p = ProviderBuilder::new().wallet(EthereumWallet::from(dev)).connect_http(rpc_url.clone());
        let amount = U256::from(1000u64) * U256::from(10u64).pow(U256::from(18u64));
        p.send_transaction(alloy::rpc::types::TransactionRequest::default().to(user_addr).value(amount))
            .await?.watch().await?;
    }
    Ok(())
}

async fn deploy_registry(rpc_url: &alloy::transports::http::reqwest::Url) -> Result<Address> {
    let deployer = MnemonicBuilder::<English>::default().phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/0")?.build()?;
    let provider = ProviderBuilder::new().wallet(EthereumWallet::from(deployer)).connect_http(rpc_url.clone());

    let artifact_path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../out/EntityRegistry.sol/EntityRegistry.json");
    let artifact: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(&artifact_path).map_err(|e| eyre::eyre!("Run `forge build` first: {e}"))?
    )?;
    let bytecode = alloy::hex::decode(
        artifact["bytecode"]["object"].as_str().ok_or_else(|| eyre::eyre!("No bytecode"))?
    )?;

    let tx = alloy::rpc::types::TransactionRequest::default().with_deploy_code(bytecode).gas_limit(5_000_000);
    let receipt = provider.send_transaction(tx).await?.get_receipt().await?;
    receipt.contract_address.ok_or_else(|| eyre::eyre!("No contract address"))
}

async fn get_block_gas_limit<P: Provider>(provider: &P) -> Result<u64> {
    let block = provider.get_block_by_number(alloy::eips::BlockNumberOrTag::Latest.into()).await?
        .ok_or_else(|| eyre::eyre!("no latest block"))?;
    Ok(block.header.inner.gas_limit)
}

async fn find_max_payload<P: Provider>(provider: &P, contract: Address, tx_size_limit: usize, gas_limit: u64) -> Result<usize> {
    let sample = EntityRegistry::executeCall {
        ops: vec![EntityRegistry::Op {
            opType: 0, entityKey: FixedBytes::ZERO, payload: Bytes::new(),
            contentType: "application/octet-stream".to_string(),
            attributes: chunk_attributes(FixedBytes::ZERO, 0, 1), expiresAt: u32::MAX,
        }],
    };
    let tx_max = tx_size_limit - TX_ENVELOPE_OVERHEAD - SolCall::abi_encode(&sample).len();

    print!("  Max chunk payload (gas {}M)... ", gas_limit / 1_000_000);
    let _ = std::io::stdout().flush();

    let mut lo: usize = 0;
    let mut hi = tx_max;
    while hi - lo > 1024 {
        let mid = (lo + hi) / 2;
        if probe_gas(provider, contract, mid).await { lo = mid; } else { hi = mid; }
    }
    println!("{}", format_bytes(lo));
    Ok(lo)
}

async fn probe_gas<P: Provider>(reader: &P, contract: Address, size: usize) -> bool {
    let op = EntityRegistry::Op {
        opType: 0, entityKey: FixedBytes::ZERO,
        payload: Bytes::from(vec![0xABu8; size]),
        contentType: "application/octet-stream".to_string(),
        attributes: chunk_attributes(FixedBytes::ZERO, 0, 1), expiresAt: u32::MAX,
    };
    let calldata = SolCall::abi_encode(&EntityRegistry::executeCall { ops: vec![op] });
    let tx = alloy::rpc::types::TransactionRequest::default()
        .to(contract)
        .input(alloy::rpc::types::TransactionInput { input: Some(calldata.into()), data: None });
    reader.estimate_gas(tx).await.is_ok()
}

// =============================================================================
// Run a single file size
// =============================================================================

async fn run_size<P: Provider>(
    reader: &P, wallet: &PrivateKeySigner,
    rpc_url: &alloy::transports::http::reqwest::Url,
    contract: Address, size_kb: u64, max_payload: usize, block_gas_limit: u64,
) -> Result<SizeResult> {
    let file_bytes = (size_kb * 1024) as usize;
    let file_data = vec![0xABu8; file_bytes];
    let file_hash = keccak256(&file_data);

    let chunk_count = if file_bytes == 0 { 1 } else { (file_bytes + max_payload - 1) / max_payload };
    let expires_at = reader.get_block_number().await? as u32 + 1_000_000;
    let mut nonce = reader.get_transaction_count(wallet.address()).await?;

    let signer = ProviderBuilder::new()
        .wallet(EthereumWallet::from(wallet.clone()))
        .connect_http(rpc_url.clone());

    let mut signed_txs: Vec<(usize, Bytes, usize)> = Vec::with_capacity(chunk_count);
    let mut total_calldata: usize = 0;

    for i in 0..chunk_count {
        let start = i * max_payload;
        let end = (start + max_payload).min(file_bytes);

        let op = EntityRegistry::Op {
            opType: 0, entityKey: FixedBytes::ZERO,
            payload: Bytes::from(file_data[start..end].to_vec()),
            contentType: "application/octet-stream".to_string(),
            attributes: chunk_attributes(file_hash, i as u64, chunk_count as u64),
            expiresAt: expires_at,
        };

        let calldata = SolCall::abi_encode(&EntityRegistry::executeCall { ops: vec![op] });
        let calldata_len = calldata.len();
        total_calldata += calldata_len;

        let est_tx = alloy::rpc::types::TransactionRequest::default()
            .to(contract)
            .input(alloy::rpc::types::TransactionInput { input: Some(Bytes::from(calldata.clone())), data: None });
        let estimated = reader.estimate_gas(est_tx).await?;
        let gas_limit = (estimated * 120 / 100).min(block_gas_limit);

        let tx = alloy::rpc::types::TransactionRequest::default()
            .to(contract)
            .input(alloy::rpc::types::TransactionInput { input: Some(calldata.into()), data: None })
            .nonce(nonce).gas_limit(gas_limit)
            .max_fee_per_gas(1_000_000_000).max_priority_fee_per_gas(1_000_000);

        let raw = match signer.fill(tx).await? {
            SendableTx::Envelope(env) => Bytes::from(env.encoded_2718()),
            _ => return Err(eyre::eyre!("unexpected sendable tx type")),
        };

        signed_txs.push((i, raw, calldata_len));
        nonce += 1;
    }

    println!("  {:>6} KB  {} chunk{}  ({} calldata)",
        size_kb, chunk_count, if chunk_count == 1 { "" } else { "s" }, format_bytes(total_calldata));

    let plain = ProviderBuilder::new().connect_http(rpc_url.clone());
    let start = Instant::now();

    let mut receipts: Vec<ChunkReceipt> = Vec::new();
    let mut failed: u64 = 0;

    // Send in batches to avoid filling the txpool.
    // ~100 chunks of 128KB = ~12.8MB per batch, well under the 20MB txpool limit.
    let batch_size = 100;
    let mut tx_iter = signed_txs.iter().peekable();

    while tx_iter.peek().is_some() {
        let batch: Vec<_> = tx_iter.by_ref().take(batch_size).collect();
        // Send batch
        let mut pending: Vec<(usize, usize, _)> = Vec::new();
        for (idx, raw, clen) in batch {
            match plain.send_raw_transaction(raw).await {
                Ok(p) => pending.push((*idx, *clen, p)),
                Err(e) => { eprintln!("    send error (chunk {idx}): {e}"); failed += 1; }
            }
        }

        // Collect receipts for this batch
        let mut handles = Vec::new();
        for (idx, clen, p) in pending {
            let rpc_url = rpc_url.clone();
            handles.push(tokio::spawn(async move {
                match tokio::time::timeout(std::time::Duration::from_secs(120), p.get_receipt()).await {
                    Ok(Ok(receipt)) => {
                        let bn = receipt.block_number.unwrap_or(0);
                        let base_fee = get_block_base_fee(&rpc_url, bn).await;
                        let csh = parse_changeset_hash(&receipt);
                        Ok(ChunkReceipt {
                            chunk_idx: idx, block_number: bn,
                            tx_index: receipt.transaction_index.unwrap_or(0),
                            gas_used: receipt.gas_used as u64,
                            base_fee, calldata_bytes: clen, changeset_hash: csh,
                        })
                    }
                    Ok(Err(e)) => Err(format!("receipt: {e}")),
                    Err(_) => Err("timeout (120s)".to_string()),
                }
            }));
        }

        for h in handles {
            match h.await {
                Ok(Ok(cr)) => receipts.push(cr),
                Ok(Err(e)) => { eprintln!("    chunk err: {e}"); failed += 1; }
                Err(e) => { eprintln!("    chunk join: {e}"); failed += 1; }
            }
        }

        if chunk_count > 1 {
            print!("\r           {}/{chunk_count} mined              ", receipts.len());
            let _ = std::io::stdout().flush();
        }
    }

    receipts.sort_by_key(|c| (c.block_number, c.tx_index));

    let elapsed = start.elapsed().as_secs_f64();
    let total_gas: u64 = receipts.iter().map(|c| c.gas_used).sum();

    if chunk_count > 1 { print!("\r"); }
    println!("           {}/{chunk_count} mined, {} gas, {:.1}s{}",
        receipts.len(), format_gas(total_gas), elapsed,
        if failed > 0 { format!(" ({failed} failed)") } else { String::new() });

    Ok(SizeResult { size_kb, chunks: receipts, failed, total_calldata })
}

// =============================================================================
// Helpers
// =============================================================================

fn chunk_attributes(hash: FixedBytes<32>, idx: u64, total: u64) -> Vec<EntityRegistry::Attribute> {
    vec![
        EntityRegistry::Attribute { name: short_string("chunk_idx"), valueType: 0,
            fixedValue: FixedBytes::from(U256::from(idx).to_be_bytes::<32>()), stringValue: String::new() },
        EntityRegistry::Attribute { name: short_string("chunk_total"), valueType: 0,
            fixedValue: FixedBytes::from(U256::from(total).to_be_bytes::<32>()), stringValue: String::new() },
        EntityRegistry::Attribute { name: short_string("file_hash"), valueType: 2,
            fixedValue: hash, stringValue: String::new() },
    ]
}

fn short_string(s: &str) -> FixedBytes<32> {
    let b = s.as_bytes();
    assert!(b.len() <= 31);
    let mut buf = [0u8; 32];
    buf[..b.len()].copy_from_slice(b);
    buf[31] = (b.len() * 2) as u8;
    FixedBytes::from(buf)
}

fn parse_changeset_hash(receipt: &alloy::rpc::types::TransactionReceipt) -> FixedBytes<32> {
    use alloy::sol_types::SolEvent;
    let sig = EntityRegistry::ChangeSetHashUpdated::SIGNATURE_HASH;
    for log in receipt.inner.logs() {
        if !log.topics().is_empty() && log.topics()[0] == sig && log.data().data.len() >= 32 {
            return FixedBytes::from_slice(&log.data().data[..32]);
        }
    }
    FixedBytes::ZERO
}

async fn get_block_base_fee(rpc_url: &alloy::transports::http::reqwest::Url, block: u64) -> u64 {
    let p = ProviderBuilder::new().connect_http(rpc_url.clone());
    match p.get_block_by_number(block.into()).await {
        Ok(Some(b)) => b.header.inner.base_fee_per_gas.unwrap_or(0),
        _ => 0,
    }
}

async fn fetch_prices(l2: Option<f64>, l1: Option<f64>, eth: Option<f64>, op_rpc: &str) -> Result<Prices> {
    let client = alloy::transports::http::reqwest::Client::new();

    let eth_price_usd = match eth {
        Some(p) => p,
        None => match client.get("https://api.coingecko.com/api/v3/simple/price?ids=ethereum&vs_currencies=usd")
            .send().await {
            Ok(r) => r.json::<serde_json::Value>().await.ok()
                .and_then(|v| v["ethereum"]["usd"].as_f64()).unwrap_or(2000.0),
            Err(_) => 2000.0,
        }
    };

    let l2_gas = match l2 {
        Some(p) => p,
        None => {
            let body = serde_json::json!({"jsonrpc":"2.0","method":"eth_gasPrice","params":[],"id":1});
            match client.post(op_rpc).json(&body).send().await {
                Ok(r) => r.json::<serde_json::Value>().await.ok()
                    .and_then(|v| v["result"].as_str().map(String::from))
                    .and_then(|h| u128::from_str_radix(h.trim_start_matches("0x"), 16).ok())
                    .map(|w| w as f64 / 1e9).unwrap_or(0.001),
                Err(_) => 0.001,
            }
        }
    };

    Ok(Prices { l2_gas_price_gwei: l2_gas, l1_data_price_gwei: l1.unwrap_or(5.0), eth_price_usd })
}

fn print_prices(p: &Prices) {
    println!("  L2 gas: {:.4} gwei | L1 data: {:.2} gwei/byte | ETH: ${:.0}",
        p.l2_gas_price_gwei, p.l1_data_price_gwei, p.eth_price_usd);
}

// =============================================================================
// Reporting
// =============================================================================

fn print_report(results: &[SizeResult], prices: &Prices) {
    use comfy_table::{Table, ContentArrangement, Cell, CellAlignment, presets};

    println!();
    println!("EntityRegistry File Upload Cost (Optimism L2 model)");
    println!("===================================================");
    print_prices(prices);
    println!();

    let mut t = Table::new();
    t.load_preset(presets::UTF8_FULL_CONDENSED);
    t.set_content_arrangement(ContentArrangement::Dynamic);
    t.set_header(vec!["File", "Chunks", "OK", "Calldata", "Gas", "L2 Cost", "L1 Cost", "Total", "USD"]);

    for r in results {
        let ok = r.chunks.len();
        let n = ok as u64 + r.failed;
        t.add_row(vec![
            Cell::new(format!("{} KB", r.size_kb)).set_alignment(CellAlignment::Right),
            Cell::new(n).set_alignment(CellAlignment::Right),
            Cell::new(if r.failed > 0 { format!("{ok}/{n}") } else { format!("{ok}") }).set_alignment(CellAlignment::Right),
            Cell::new(format_bytes(r.total_calldata)).set_alignment(CellAlignment::Right),
            Cell::new(format_gas(r.total_gas())).set_alignment(CellAlignment::Right),
            Cell::new(format_eth(r.l2_cost_eth(prices.l2_gas_price_gwei))).set_alignment(CellAlignment::Right),
            Cell::new(format_eth(r.l1_cost_eth(prices.l1_data_price_gwei))).set_alignment(CellAlignment::Right),
            Cell::new(format_eth(r.total_eth(prices))).set_alignment(CellAlignment::Right),
            Cell::new(format_usd(r.total_usd(prices))).set_alignment(CellAlignment::Right),
        ]);
    }
    println!("{t}");

    for r in results {
        if r.chunks.len() <= 1 { continue; }
        println!();
        println!("{} KB — per-chunk detail:", r.size_kb);

        let (l2g, l1g) = (prices.l2_gas_price_gwei, prices.l1_data_price_gwei);
        let mut d = Table::new();
        d.load_preset(presets::UTF8_FULL_CONDENSED);
        d.set_content_arrangement(ContentArrangement::Dynamic);
        d.set_header(vec!["changeSetHash", "Chunk", "Block", "TxIdx", "Gas", "Base Fee", "L2 (ETH)", "L1 (ETH)", "Total (ETH)", "USD"]);

        for c in &r.chunks {
            let l2 = c.l2_cost_eth(l2g);
            let l1 = c.l1_cost_eth(l1g);
            let tot = l2 + l1;
            d.add_row(vec![
                Cell::new(short_hash(c.changeset_hash)),
                Cell::new(c.chunk_idx).set_alignment(CellAlignment::Right),
                Cell::new(c.block_number).set_alignment(CellAlignment::Right),
                Cell::new(c.tx_index).set_alignment(CellAlignment::Right),
                Cell::new(format_gas(c.gas_used)).set_alignment(CellAlignment::Right),
                Cell::new(format!("{} gwei", format_gwei(c.base_fee))).set_alignment(CellAlignment::Right),
                Cell::new(format_eth(l2)).set_alignment(CellAlignment::Right),
                Cell::new(format_eth(l1)).set_alignment(CellAlignment::Right),
                Cell::new(format_eth(tot)).set_alignment(CellAlignment::Right),
                Cell::new(format_usd(tot * prices.eth_price_usd)).set_alignment(CellAlignment::Right),
            ]);
        }
        println!("{d}");

        if r.chunks.len() >= 2 {
            let f = r.chunks.first().unwrap().base_fee;
            let l = r.chunks.last().unwrap().base_fee;
            if f > 0 {
                println!("Base fee: {} → {} gwei ({:+.1}%)", format_gwei(f), format_gwei(l),
                    (l as f64 - f as f64) / f as f64 * 100.0);
            } else {
                println!("Base fee: {} → {} gwei", format_gwei(f), format_gwei(l));
            }
        }
    }

    println!();
    let mut b = Table::new();
    b.load_preset(presets::UTF8_FULL_CONDENSED);
    b.set_content_arrangement(ContentArrangement::Dynamic);
    b.set_header(vec!["File", "Chunks", "USD", "L2 Cost", "L1 Cost", "L1 %"]);
    for r in results {
        let l2 = r.l2_cost_eth(prices.l2_gas_price_gwei);
        let l1 = r.l1_cost_eth(prices.l1_data_price_gwei);
        let tot = r.total_eth(prices);
        let n = r.chunks.len() as u64 + r.failed;
        b.add_row(vec![
            Cell::new(format!("{} KB", r.size_kb)).set_alignment(CellAlignment::Right),
            Cell::new(n).set_alignment(CellAlignment::Right),
            Cell::new(format_usd(r.total_usd(prices))).set_alignment(CellAlignment::Right),
            Cell::new(format_eth(l2)).set_alignment(CellAlignment::Right),
            Cell::new(format_eth(l1)).set_alignment(CellAlignment::Right),
            Cell::new(format!("{:.0}%", if tot > 0.0 { l1 / tot * 100.0 } else { 0.0 })).set_alignment(CellAlignment::Right),
        ]);
    }
    println!("{b}");
    println!();
}

// =============================================================================
// Formatting
// =============================================================================

fn short_hash(h: FixedBytes<32>) -> String {
    let s = format!("{h}");
    if s.len() > 14 { format!("{}...{}", &s[..6], &s[s.len()-4..]) } else { s }
}

fn format_gwei(wei: u64) -> String {
    let g = wei as f64 / 1e9;
    if g == 0.0 { "0".into() }
    else if g < 0.000001 { format!("{:.9}", g) }
    else if g < 0.001 { format!("{:.6}", g) }
    else if g < 1.0 { format!("{:.4}", g) }
    else { format!("{:.2}", g) }
}

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
    if eth == 0.0 { "0".into() }
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
