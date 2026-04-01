use std::sync::Arc;
use std::time::Instant;

use alloy::{
    network::EthereumWallet,
    primitives::{Address, U256},
    providers::{Provider, ProviderBuilder},
    signers::local::PrivateKeySigner,
};
use eyre::Result;
use tokio::sync::Semaphore;

use crate::accounts;
use crate::config::{Profile, RunArgs};
use crate::metrics::{self, Report};
use crate::workloads::{self, WalletState, WorkloadTx};

pub async fn run(args: &RunArgs) -> Result<Report> {
    let contract_addr = args.contract_address()?;
    let rpc_url: alloy::transports::http::reqwest::Url = args.rpc_url.parse()?;

    // 1. Connect to reth
    let provider = ProviderBuilder::new().connect_http(rpc_url.clone());
    let chain_id = provider.get_chain_id().await?;
    println!("Connected to chain {chain_id} at {}", args.rpc_url);

    // 2. Generate and fund accounts
    let wallets = accounts::derive_wallets(args.accounts)?;
    let eth_per_account = U256::from_str_radix(
        args.eth_per_account.trim_start_matches("0x"),
        if args.eth_per_account.starts_with("0x") {
            16
        } else {
            10
        },
    )?;

    println!("Funding {} accounts...", wallets.len());

    // Build a wallet-backed provider for the dev account (for funding)
    let dev_wallet = accounts::dev_wallet()?;
    let dev_provider = ProviderBuilder::new()
        .wallet(EthereumWallet::from(dev_wallet))
        .connect_http(rpc_url.clone());
    accounts::fund_accounts(&dev_provider, &wallets, eth_per_account, chain_id).await?;

    // 3. Initialize wallet states
    let mut wallet_states: Vec<WalletState> = Vec::new();
    for w in &wallets {
        let addr: Address = w.address();
        let tx_nonce = provider.get_transaction_count(addr).await?;
        wallet_states.push(WalletState {
            address: addr,
            contract_nonce: 0,
            tx_nonce,
        });
    }

    // 4. Seed phase (if needed)
    let current_block = provider.get_block_number().await? as u32;
    if args.profile.needs_seed() {
        let entities_per_wallet =
            compute_entities_needed(&args.profile, args.duration, wallets.len());
        println!("Seeding {entities_per_wallet} entities per wallet...");

        let (seed_txs, _) =
            workloads::build_seed_creates(&mut wallet_states, entities_per_wallet, current_block);

        // Reset contract nonces — they'll be set by the seed creates
        for ws in &mut wallet_states {
            ws.contract_nonce = 0;
        }

        submit_and_wait(
            &rpc_url,
            &wallets,
            &mut wallet_states,
            seed_txs,
            contract_addr,
            chain_id,
            args.concurrency,
        )
        .await?;

        // Update contract nonces after seed
        for ws in &mut wallet_states {
            ws.contract_nonce = entities_per_wallet as u32;
        }

        println!("Seed phase complete.");
    }

    // 5. Build workload
    let total_ops = (args.duration as f64 * args.profile.theoretical_ops_per_sec()) as u64;
    let total_ops = total_ops.max(1);
    let current_block = provider.get_block_number().await? as u32;

    println!(
        "Building workload: {} ops ({:?} profile, batch_size={})...",
        total_ops, args.profile, args.batch_size
    );

    let workload_txs = workloads::build_workload(
        &args.profile,
        &mut wallet_states,
        total_ops,
        args.batch_size,
        chain_id,
        contract_addr,
        current_block,
    );

    println!("Submitting {} transactions...", workload_txs.len());

    // 6. Record start block + time
    let start_block = provider.get_block_number().await?;
    let start_time = Instant::now();

    // 7. Sign and blast
    submit_and_wait(
        &rpc_url,
        &wallets,
        &mut wallet_states,
        workload_txs,
        contract_addr,
        chain_id,
        args.concurrency,
    )
    .await?;

    // 8. Record end
    let elapsed = start_time.elapsed();
    let end_block = provider.get_block_number().await?;

    println!(
        "All transactions mined. Blocks {}..{}, {:.1}s elapsed.",
        start_block,
        end_block,
        elapsed.as_secs_f64()
    );

    // 9. Collect metrics
    let report = metrics::collect(
        &provider,
        contract_addr,
        start_block,
        end_block,
        elapsed,
        &args.profile,
    )
    .await?;

    Ok(report)
}

async fn submit_and_wait(
    rpc_url: &alloy::transports::http::reqwest::Url,
    wallets: &[PrivateKeySigner],
    wallet_states: &mut [WalletState],
    txs: Vec<WorkloadTx>,
    contract_addr: Address,
    _chain_id: u64,
    concurrency: usize,
) -> Result<()> {
    let semaphore = Arc::new(Semaphore::new(concurrency));
    let mut handles = Vec::with_capacity(txs.len());

    for wtx in txs {
        let wallet = wallets[wtx.wallet_idx].clone();
        let ws = &mut wallet_states[wtx.wallet_idx];
        let nonce = ws.tx_nonce;
        ws.tx_nonce += 1;

        // Build the transaction
        let call = crate::abi::EntityRegistry::executeCall { ops: wtx.ops };
        let calldata = alloy::sol_types::SolCall::abi_encode(&call);

        let tx = alloy::rpc::types::TransactionRequest::default()
            .to(contract_addr)
            .input(alloy::rpc::types::TransactionInput {
                input: Some(calldata.into()),
                data: None,
            })
            .nonce(nonce)
            .gas_limit(60_000_000)
            .max_fee_per_gas(20_000_000_000)
            .max_priority_fee_per_gas(1_000_000_000);

        let eth_wallet = EthereumWallet::from(wallet);
        let provider = ProviderBuilder::new()
            .wallet(eth_wallet)
            .connect_http(rpc_url.clone());

        let permit = semaphore.clone().acquire_owned().await?;
        let handle = tokio::spawn(async move {
            let result = provider.send_transaction(tx).await;
            drop(permit);
            match result {
                Ok(pending) => {
                    let _ = pending.watch().await;
                    Ok(())
                }
                Err(e) => {
                    eprintln!("tx send error: {e}");
                    Err(e)
                }
            }
        });

        handles.push(handle);
    }

    let mut errors = 0u64;
    for handle in handles {
        match handle.await {
            Ok(Ok(())) => {}
            Ok(Err(_)) => errors += 1,
            Err(e) => {
                eprintln!("task join error: {e}");
                errors += 1;
            }
        }
    }

    if errors > 0 {
        eprintln!("WARNING: {errors} transactions failed");
    }

    Ok(())
}

fn compute_entities_needed(profile: &Profile, duration: u64, num_wallets: usize) -> u64 {
    let total_ops = (duration as f64 * profile.theoretical_ops_per_sec()) as u64;
    let per_wallet = (total_ops / num_wallets as u64) + 1;
    per_wallet
}
