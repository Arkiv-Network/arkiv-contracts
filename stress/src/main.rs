mod abi;

use std::io::Write;
use std::time::Instant;

use alloy::{
    eips::Encodable2718,
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
const TX_ENVELOPE_OVERHEAD: usize = 256;
const DEFAULT_TX_SIZE_LIMIT: usize = 10 * 1024 * 1024; // 10 MB, matches start-reth.sh

#[derive(Parser)]
#[command(name = "arkiv-stress", about = "EntityRegistry file upload throughput test")]
struct Cli {
    /// JSON-RPC endpoint
    #[arg(long, default_value = "http://127.0.0.1:8545")]
    rpc_url: String,

    /// File sizes to test in KB (comma-separated)
    #[arg(long, default_value = "1,10,100,1000,10000", value_delimiter = ',')]
    sizes: Vec<u64>,

    /// Max transaction size in bytes (must match --txpool.max-tx-input-bytes on reth)
    #[arg(long, default_value_t = DEFAULT_TX_SIZE_LIMIT)]
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

/// Per-chunk on-chain data, sorted by execution order.
struct ChunkReceipt {
    chunk_idx: usize,
    block_number: u64,
    tx_index: u64,
    gas_used: u64,
    base_fee: u64, // wei
    calldata_bytes: usize,
    changeset_hash: FixedBytes<32>,
}

impl ChunkReceipt {
    /// Projected L2 execution cost using configured OP gas price
    fn l2_cost_eth(&self, l2_gwei: f64) -> f64 {
        self.gas_used as f64 * l2_gwei * 1e-9
    }

    /// Projected L1 data cost using configured rate
    fn l1_cost_eth(&self, l1_gwei: f64) -> f64 {
        self.calldata_bytes as f64 * l1_gwei * 1e-9
    }

}

struct SizeResult {
    size_kb: u64,
    chunks: Vec<ChunkReceipt>,
    failed: u64,
    total_calldata: usize,
}

impl SizeResult {
    fn total_gas(&self) -> u64 {
        self.chunks.iter().map(|c| c.gas_used).sum()
    }
    fn l2_cost_eth(&self, l2_gwei: f64) -> f64 {
        self.total_gas() as f64 * l2_gwei * 1e-9
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

    println!("Deploying EntityRegistry...");
    let contract_addr = deploy_registry(&rpc_url).await?;
    println!("  Deployed at: {contract_addr}");

    let block = provider.get_block_by_number(alloy::eips::BlockNumberOrTag::Latest.into()).await?
        .ok_or_else(|| eyre::eyre!("no latest block"))?;
    let block_gas_limit = block.header.inner.gas_limit;

    let tx_size_max = compute_max_payload_from_tx_size(cli.tx_size_limit);
    print!("  Finding max chunk payload (block gas {}M)... ", block_gas_limit / 1_000_000);
    let _ = std::io::stdout().flush();
    let max_payload = find_max_payload_by_gas(&provider, contract_addr, tx_size_max).await?;
    println!("{}", format_bytes(max_payload));
    println!();

    let user_wallet = MnemonicBuilder::<English>::default()
        .phrase(MNEMONIC).derivation_path("m/44'/60'/0'/0/1")?.build()?;

    let mut results = Vec::new();
    for &size_kb in &cli.sizes {
        let r = run_size(&provider, &user_wallet, &rpc_url, contract_addr, size_kb, max_payload, block_gas_limit).await?;
        results.push(r);
    }

    print_report(&results, &prices);
    Ok(())
}

fn compute_max_payload_from_tx_size(tx_size_limit: usize) -> usize {
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
    tx_size_limit - TX_ENVELOPE_OVERHEAD - SolCall::abi_encode(&sample).len()
}

/// Binary search for the largest payload that fits in the block gas limit.
/// Uses eth_estimateGas against the live chain to account for memory expansion costs.
async fn find_max_payload_by_gas<P: Provider>(
    reader: &P,
    contract: Address,
    tx_size_max: usize,
) -> Result<usize> {
    let mut lo: usize = 0;
    let mut hi: usize = tx_size_max;

    // ~8 iterations for convergence
    while hi - lo > 1024 {
        let mid = (lo + hi) / 2;
        if probe_gas(reader, contract, mid).await {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    Ok(lo)
}

async fn probe_gas<P: Provider>(reader: &P, contract: Address, payload_size: usize) -> bool {
    let payload = vec![0xABu8; payload_size];
    let op = EntityRegistry::Op {
        opType: 0,
        entityKey: FixedBytes::ZERO,
        payload: Bytes::from(payload),
        contentType: "application/octet-stream".to_string(),
        attributes: chunk_attributes(FixedBytes::ZERO, 0, 1),
        expiresAt: u32::MAX,
    };
    let calldata = SolCall::abi_encode(&EntityRegistry::executeCall { ops: vec![op] });
    let tx = alloy::rpc::types::TransactionRequest::default()
        .to(contract)
        .input(alloy::rpc::types::TransactionInput {
            input: Some(calldata.into()),
            data: None,
        });
    reader.estimate_gas(tx).await.is_ok()
}

fn chunk_attributes(file_hash: FixedBytes<32>, idx: u64, total: u64) -> Vec<EntityRegistry::Attribute> {
    vec![
        uint_attr("chunk_idx", idx),
        uint_attr("chunk_total", total),
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
    assert!(bytes.len() <= 31);
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
        .as_str().ok_or_else(|| eyre::eyre!("No bytecode in artifact"))?;
    let bytecode = alloy::hex::decode(bytecode_hex)?;

    let tx = alloy::rpc::types::TransactionRequest::default()
        .with_deploy_code(bytecode)
        .gas_limit(5_000_000);
    let receipt = provider.send_transaction(tx).await?.get_receipt().await?;
    receipt.contract_address.ok_or_else(|| eyre::eyre!("No contract address in receipt"))
}

async fn run_size<P: Provider>(
    reader: &P,
    user_wallet: &alloy::signers::local::PrivateKeySigner,
    rpc_url: &alloy::transports::http::reqwest::Url,
    contract: Address,
    size_kb: u64,
    max_payload: usize,
    block_gas_limit: u64,
) -> Result<SizeResult> {
    let file_bytes = (size_kb * 1024) as usize;
    let file_data = vec![0xABu8; file_bytes];
    let file_hash = keccak256(&file_data);

    let chunk_count = if file_bytes == 0 { 1 } else { (file_bytes + max_payload - 1) / max_payload };
    let expires_at = reader.get_block_number().await? as u32 + 1_000_000;
    let mut nonce = reader.get_transaction_count(user_wallet.address()).await?;

    let signer_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(user_wallet.clone()))
        .connect_http(rpc_url.clone());

    // Build, estimate, sign all chunks
    let mut signed_txs: Vec<(usize, Bytes, usize)> = Vec::with_capacity(chunk_count); // (chunk_idx, raw, calldata_len)
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
        let calldata_len = calldata.len();
        total_calldata += calldata_len;

        // Estimate gas
        let tx_for_estimate = alloy::rpc::types::TransactionRequest::default()
            .to(contract)
            .input(alloy::rpc::types::TransactionInput {
                input: Some(Bytes::from(calldata.clone())),
                data: None,
            });
        let estimated = reader.estimate_gas(tx_for_estimate).await?;
        let gas_limit = (estimated * 120 / 100).min(block_gas_limit);

        let tx = alloy::rpc::types::TransactionRequest::default()
            .to(contract)
            .input(alloy::rpc::types::TransactionInput {
                input: Some(calldata.into()),
                data: None,
            })
            .nonce(nonce)
            .gas_limit(gas_limit)
            .max_fee_per_gas(1_000_000_000)    // 1 gwei — plenty for a dev chain
            .max_priority_fee_per_gas(1_000_000); // 0.001 gwei

        let sendable = signer_provider.fill(tx).await?;
        let raw = match sendable {
            SendableTx::Envelope(env) => Bytes::from(env.encoded_2718()),
            _ => return Err(eyre::eyre!("unexpected sendable tx type")),
        };

        signed_txs.push((i, raw, calldata_len));
        nonce += 1;
    }

    println!(
        "  {:>6} KB  {} chunk{}  ({} calldata)",
        size_kb, chunk_count,
        if chunk_count == 1 { "" } else { "s" },
        format_bytes(total_calldata),
    );

    // Blast all into mempool
    let plain_provider = ProviderBuilder::new().connect_http(rpc_url.clone());
    let start = Instant::now();

    let mut pending_txs: Vec<(usize, usize, _)> = Vec::new(); // (chunk_idx, calldata_len, pending)
    let mut failed: u64 = 0;

    for (chunk_idx, raw, calldata_len) in &signed_txs {
        match plain_provider.send_raw_transaction(raw).await {
            Ok(pending) => pending_txs.push((*chunk_idx, *calldata_len, pending)),
            Err(e) => {
                eprintln!("    send error (chunk {chunk_idx}): {e}");
                failed += 1;
            }
        }
    }

    let sent = pending_txs.len();
    if chunk_count > 1 {
        print!("           {sent}/{chunk_count} sent, collecting receipts...");
        let _ = std::io::stdout().flush();
    }

    // Collect receipts — parallel await, then sort by chain order
    let mut receipt_handles = Vec::new();
    for (chunk_idx, calldata_len, pending) in pending_txs {
        let rpc_url = rpc_url.clone();
        receipt_handles.push(tokio::spawn(async move {
            match pending.get_receipt().await {
                Ok(receipt) => {
                    let block_num = receipt.block_number.unwrap_or(0);
                    let base_fee = get_block_base_fee(&rpc_url, block_num).await;
                    let changeset_hash = parse_changeset_hash(&receipt);

                    Ok(ChunkReceipt {
                        chunk_idx,
                        block_number: block_num,
                        tx_index: receipt.transaction_index.unwrap_or(0),
                        gas_used: receipt.gas_used as u64,
                        base_fee,
                        calldata_bytes: calldata_len,
                        changeset_hash,
                    })
                }
                Err(e) => Err(e),
            }
        }));
    }

    let mut chunk_receipts: Vec<ChunkReceipt> = Vec::new();
    for (i, handle) in receipt_handles.into_iter().enumerate() {
        match handle.await {
            Ok(Ok(cr)) => {
                if chunk_count > 1 {
                    let done = chunk_receipts.len() + 1;
                    print!("\r           {done}/{sent} mined              ");
                    let _ = std::io::stdout().flush();
                }
                chunk_receipts.push(cr);
            }
            Ok(Err(e)) => {
                eprintln!("\n    receipt error (chunk {i}): {e}");
                failed += 1;
            }
            Err(e) => {
                eprintln!("\n    join error (chunk {i}): {e}");
                failed += 1;
            }
        }
    }

    // Sort by chain execution order
    chunk_receipts.sort_by_key(|c| (c.block_number, c.tx_index));

    let elapsed = start.elapsed().as_secs_f64();
    let total_gas: u64 = chunk_receipts.iter().map(|c| c.gas_used).sum();

    if chunk_count > 1 { print!("\r"); }
    println!(
        "           {}/{chunk_count} mined, {} gas, {:.1}s{}",
        chunk_receipts.len(), format_gas(total_gas), elapsed,
        if failed > 0 { format!(" ({failed} failed)") } else { String::new() },
    );

    Ok(SizeResult {
        size_kb,
        chunks: chunk_receipts,
        failed,
        total_calldata,
    })
}

fn parse_changeset_hash(receipt: &alloy::rpc::types::TransactionReceipt) -> FixedBytes<32> {
    use alloy::sol_types::SolEvent;
    let sig = EntityRegistry::ChangeSetHashUpdated::SIGNATURE_HASH;
    for log in receipt.inner.logs() {
        let topics = log.topics();
        if !topics.is_empty() && topics[0] == sig {
            // ChangeSetHashUpdated has one non-indexed bytes32 in data
            if log.data().data.len() >= 32 {
                return FixedBytes::from_slice(&log.data().data[..32]);
            }
        }
    }
    FixedBytes::ZERO
}

async fn get_block_base_fee(
    rpc_url: &alloy::transports::http::reqwest::Url,
    block_num: u64,
) -> u64 {
    let provider = ProviderBuilder::new().connect_http(rpc_url.clone());
    match provider.get_block_by_number(block_num.into()).await {
        Ok(Some(block)) => block.header.inner.base_fee_per_gas.unwrap_or(0),
        _ => 0,
    }
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
            Err(_) => { eprintln!("  Could not fetch ETH price, using $2000"); 2000.0 }
        }
    };

    let l2_gas_price_gwei = if let Some(p) = cli.l2_gas_price_gwei {
        p
    } else {
        match fetch_op_gas_price(&client, &cli.op_rpc_url).await {
            Ok(p) => p,
            Err(_) => { eprintln!("  Could not fetch OP gas price, using 0.001 gwei"); 0.001 }
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
    println!();

    use comfy_table::{Table, ContentArrangement, Cell, CellAlignment, presets};

    // Summary table
    let mut summary = Table::new();
    summary.load_preset(presets::UTF8_FULL_CONDENSED);
    summary.set_content_arrangement(ContentArrangement::Dynamic);
    summary.set_header(vec!["File", "Chunks", "OK", "Calldata", "Gas", "L2 Cost", "L1 Cost", "Total", "USD"]);

    for r in results {
        let ok = r.chunks.len();
        let total_chunks = ok as u64 + r.failed;
        let status = if r.failed > 0 { format!("{ok}/{total_chunks}") } else { format!("{ok}") };

        summary.add_row(vec![
            Cell::new(format!("{} KB", r.size_kb)).set_alignment(CellAlignment::Right),
            Cell::new(total_chunks).set_alignment(CellAlignment::Right),
            Cell::new(status).set_alignment(CellAlignment::Right),
            Cell::new(format_bytes(r.total_calldata)).set_alignment(CellAlignment::Right),
            Cell::new(format_gas(r.total_gas())).set_alignment(CellAlignment::Right),
            Cell::new(format_eth(r.l2_cost_eth(prices.l2_gas_price_gwei))).set_alignment(CellAlignment::Right),
            Cell::new(format_eth(r.l1_cost_eth(prices.l1_data_price_gwei))).set_alignment(CellAlignment::Right),
            Cell::new(format_eth(r.total_eth(prices))).set_alignment(CellAlignment::Right),
            Cell::new(format_usd(r.total_usd(prices))).set_alignment(CellAlignment::Right),
        ]);
    }
    println!("{summary}");

    // Per-chunk detail for multi-chunk files
    for r in results {
        if r.chunks.len() <= 1 { continue; }

        println!();
        println!("{} KB — per-chunk detail (chain order):", r.size_kb);

        let mut detail = Table::new();
        detail.load_preset(presets::UTF8_FULL_CONDENSED);
        detail.set_content_arrangement(ContentArrangement::Dynamic);
        let l2g = prices.l2_gas_price_gwei;
        let l1g = prices.l1_data_price_gwei;
        detail.set_header(vec!["changeSetHash", "Chunk", "Block", "TxIdx", "Gas Used", "Base Fee", "L2 (ETH)", "L1 (ETH)", "Total (ETH)", "USD"]);

        for c in &r.chunks {
            let l2 = c.l2_cost_eth(l2g);
            let l1 = c.l1_cost_eth(l1g);
            let total = l2 + l1;
            detail.add_row(vec![
                Cell::new(short_hash(c.changeset_hash)),
                Cell::new(c.chunk_idx).set_alignment(CellAlignment::Right),
                Cell::new(c.block_number).set_alignment(CellAlignment::Right),
                Cell::new(c.tx_index).set_alignment(CellAlignment::Right),
                Cell::new(format_gas(c.gas_used)).set_alignment(CellAlignment::Right),
                Cell::new(format!("{} gwei", format_gwei(c.base_fee))).set_alignment(CellAlignment::Right),
                Cell::new(format_eth(l2)).set_alignment(CellAlignment::Right),
                Cell::new(format_eth(l1)).set_alignment(CellAlignment::Right),
                Cell::new(format_eth(total)).set_alignment(CellAlignment::Right),
                Cell::new(format_usd(total * prices.eth_price_usd)).set_alignment(CellAlignment::Right),
            ]);
        }
        println!("{detail}");

        // Base fee trend
        if r.chunks.len() >= 2 {
            let first_base = r.chunks.first().unwrap().base_fee;
            let last_base = r.chunks.last().unwrap().base_fee;
            if first_base > 0 {
                let change_pct = (last_base as f64 - first_base as f64) / first_base as f64 * 100.0;
                println!("Base fee: {} → {} gwei ({:+.1}% over {} chunks)",
                    format_gwei(first_base), format_gwei(last_base), change_pct, r.chunks.len());
            } else {
                println!("Base fee: {} → {} gwei ({} chunks)",
                    format_gwei(first_base), format_gwei(last_base), r.chunks.len());
            }
        }
    }

    // Cost breakdown
    println!();
    let mut breakdown = Table::new();
    breakdown.load_preset(presets::UTF8_FULL_CONDENSED);
    breakdown.set_content_arrangement(ContentArrangement::Dynamic);
    breakdown.set_header(vec!["File", "Chunks", "USD", "L2 Cost", "L1 Cost", "L1 %"]);

    for r in results {
        let l2 = r.l2_cost_eth(prices.l2_gas_price_gwei);
        let l1 = r.l1_cost_eth(prices.l1_data_price_gwei);
        let total = r.total_eth(prices);
        let l1_pct = if total > 0.0 { l1 / total * 100.0 } else { 0.0 };
        let total_chunks = r.chunks.len() as u64 + r.failed;
        let fail = if r.failed > 0 { format!(" ({} err)", r.failed) } else { String::new() };

        breakdown.add_row(vec![
            Cell::new(format!("{} KB", r.size_kb)).set_alignment(CellAlignment::Right),
            Cell::new(format!("{total_chunks}{fail}")).set_alignment(CellAlignment::Right),
            Cell::new(format_usd(r.total_usd(prices))).set_alignment(CellAlignment::Right),
            Cell::new(format_eth(l2)).set_alignment(CellAlignment::Right),
            Cell::new(format_eth(l1)).set_alignment(CellAlignment::Right),
            Cell::new(format!("{:.0}%", l1_pct)).set_alignment(CellAlignment::Right),
        ]);
    }
    println!("{breakdown}");
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

fn short_hash(h: FixedBytes<32>) -> String {
    let s = format!("{h}");
    if s.len() > 14 {
        format!("{}...{}", &s[..6], &s[s.len()-4..])
    } else {
        s
    }
}

/// Format wei as gwei with appropriate precision.
fn format_gwei(wei: u64) -> String {
    let gwei = wei as f64 / 1e9;
    if gwei == 0.0 { "0".to_string() }
    else if gwei < 0.000001 { format!("{:.9}", gwei) }
    else if gwei < 0.001 { format!("{:.6}", gwei) }
    else if gwei < 1.0 { format!("{:.4}", gwei) }
    else { format!("{:.2}", gwei) }
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

