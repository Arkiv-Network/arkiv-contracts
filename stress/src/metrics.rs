use std::time::Duration;

use alloy::{
    primitives::Address,
    providers::Provider,
    rpc::types::Filter,
    sol_types::SolEvent,
};
use eyre::Result;

use crate::abi::EntityRegistry;
use crate::config::Profile;

#[derive(Debug, serde::Serialize)]
pub struct BlockStats {
    pub number: u64,
    pub timestamp: u64,
    pub gas_used: u64,
    pub gas_limit: u64,
    pub transactions: usize,
    pub operations: u64,
    pub utilization: f64,
}

#[derive(Debug, serde::Serialize)]
pub struct Report {
    pub profile: String,
    pub duration_secs: f64,
    pub num_blocks: u64,
    pub total_ops: u64,
    pub total_txs: u64,
    pub total_gas: u64,
    pub ops_per_sec: f64,
    pub avg_gas_per_block: f64,
    pub avg_ops_per_block: f64,
    pub avg_gas_per_op: f64,
    pub avg_utilization: f64,
    pub peak_ops_per_block: u64,
    pub theoretical_ops_per_sec: f64,
    pub actual_vs_theoretical: f64,
    pub change_set_hash: String,
    pub blocks: Vec<BlockStats>,
}

pub async fn collect<P: Provider>(
    provider: &P,
    contract_addr: Address,
    start_block: u64,
    end_block: u64,
    elapsed: Duration,
    profile: &Profile,
) -> Result<Report> {
    let mut blocks = Vec::new();
    let mut total_ops: u64 = 0;
    let mut total_txs: u64 = 0;
    let mut total_gas: u64 = 0;

    for block_num in start_block..=end_block {
        let block = provider
            .get_block_by_number(block_num.into())
            .await?
            .ok_or_else(|| eyre::eyre!("block {block_num} not found"))?;

        let gas_used = block.header.inner.gas_used;
        let gas_limit = block.header.inner.gas_limit;
        let timestamp = block.header.inner.timestamp;
        let num_txs = block.transactions.len();

        let ops = count_ops(provider, contract_addr, block_num).await?;

        let utilization = if gas_limit > 0 {
            gas_used as f64 / gas_limit as f64
        } else {
            0.0
        };

        blocks.push(BlockStats {
            number: block_num,
            timestamp,
            gas_used,
            gas_limit,
            transactions: num_txs,
            operations: ops,
            utilization,
        });

        total_ops += ops;
        total_txs += num_txs as u64;
        total_gas += gas_used;
    }

    let duration_secs = elapsed.as_secs_f64();
    let num_blocks = if end_block >= start_block {
        end_block - start_block + 1
    } else {
        0
    };

    let theoretical = profile.theoretical_ops_per_sec();
    let ops_per_sec = if duration_secs > 0.0 {
        total_ops as f64 / duration_secs
    } else {
        0.0
    };

    let change_set_hash = read_change_set_hash(provider, contract_addr).await?;

    Ok(Report {
        profile: format!("{:?}", profile),
        duration_secs,
        num_blocks,
        total_ops,
        total_txs,
        total_gas,
        ops_per_sec,
        avg_gas_per_block: if num_blocks > 0 {
            total_gas as f64 / num_blocks as f64
        } else {
            0.0
        },
        avg_ops_per_block: if num_blocks > 0 {
            total_ops as f64 / num_blocks as f64
        } else {
            0.0
        },
        avg_gas_per_op: if total_ops > 0 {
            total_gas as f64 / total_ops as f64
        } else {
            0.0
        },
        avg_utilization: if !blocks.is_empty() {
            blocks.iter().map(|b| b.utilization).sum::<f64>() / blocks.len() as f64
        } else {
            0.0
        },
        peak_ops_per_block: blocks.iter().map(|b| b.operations).max().unwrap_or(0),
        theoretical_ops_per_sec: theoretical,
        actual_vs_theoretical: if theoretical > 0.0 {
            ops_per_sec / theoretical
        } else {
            0.0
        },
        change_set_hash,
        blocks,
    })
}

async fn count_ops<P: Provider>(
    provider: &P,
    contract_addr: Address,
    block_num: u64,
) -> Result<u64> {
    let filter = Filter::new()
        .address(contract_addr)
        .from_block(block_num)
        .to_block(block_num);

    let logs = provider.get_logs(&filter).await?;

    let mut count: u64 = 0;
    for log in &logs {
        let topics = log.topics();
        if topics.is_empty() {
            continue;
        }
        let sig = topics[0];
        if sig == EntityRegistry::EntityCreated::SIGNATURE_HASH
            || sig == EntityRegistry::EntityUpdated::SIGNATURE_HASH
            || sig == EntityRegistry::EntityExtended::SIGNATURE_HASH
            || sig == EntityRegistry::EntityDeleted::SIGNATURE_HASH
            || sig == EntityRegistry::EntityExpired::SIGNATURE_HASH
        {
            count += 1;
        }
    }

    Ok(count)
}

async fn read_change_set_hash<P: Provider>(
    provider: &P,
    contract_addr: Address,
) -> Result<String> {
    let call = EntityRegistry::changeSetHashCall {};
    let calldata = alloy::sol_types::SolCall::abi_encode(&call);

    let result = provider
        .call(
            alloy::rpc::types::TransactionRequest::default()
                .to(contract_addr)
                .input(alloy::rpc::types::TransactionInput {
                    input: Some(calldata.into()),
                    data: None,
                }),
        )
        .await?;

    Ok(format!("0x{}", alloy::hex::encode(&result)))
}

pub fn print_table(report: &Report) {
    println!();
    println!("============================================================");
    println!("         EntityRegistry Stress Test Report");
    println!("============================================================");
    println!("  Profile:              {:>30}", report.profile);
    println!("  Duration:             {:>27.1} s", report.duration_secs);
    println!("  Blocks:               {:>30}", report.num_blocks);
    println!("------------------------------------------------------------");
    println!("  Total operations:     {:>30}", report.total_ops);
    println!("  Total transactions:   {:>30}", report.total_txs);
    println!(
        "  Total gas:            {:>30}",
        format_gas(report.total_gas)
    );
    println!("------------------------------------------------------------");
    println!("  Ops/sec:              {:>27.1}   ", report.ops_per_sec);
    println!(
        "  Theoretical ops/sec:  {:>27.1}   ",
        report.theoretical_ops_per_sec
    );
    println!(
        "  Actual/Theoretical:   {:>26.1}%   ",
        report.actual_vs_theoretical * 100.0
    );
    println!("------------------------------------------------------------");
    println!(
        "  Avg gas/op:           {:>30}",
        format_gas(report.avg_gas_per_op as u64)
    );
    println!(
        "  Avg ops/block:        {:>27.1}   ",
        report.avg_ops_per_block
    );
    println!(
        "  Peak ops/block:       {:>30}",
        report.peak_ops_per_block
    );
    println!(
        "  Avg utilization:      {:>26.1}%   ",
        report.avg_utilization * 100.0
    );
    println!("------------------------------------------------------------");
    println!("  changeSetHash:");
    println!("    {}", report.change_set_hash);
    println!("============================================================");
}

fn format_gas(gas: u64) -> String {
    if gas >= 1_000_000_000 {
        format!("{:.2}B", gas as f64 / 1_000_000_000.0)
    } else if gas >= 1_000_000 {
        format!("{:.2}M", gas as f64 / 1_000_000.0)
    } else if gas >= 1_000 {
        format!("{:.1}K", gas as f64 / 1_000.0)
    } else {
        format!("{gas}")
    }
}
