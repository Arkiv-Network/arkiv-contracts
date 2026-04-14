use comfy_table::{
    modifiers::UTF8_ROUND_CORNERS, presets::UTF8_FULL, Attribute, Cell, Color,
    ContentArrangement, Table,
};
use eyre::Result;
use gas_profiler_lib::analysis::AnalysisReport;
use std::path::Path;

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

fn format_gas(gas: u64) -> String {
    let s = gas.to_string();
    let mut result = String::new();
    for (i, c) in s.chars().rev().enumerate() {
        if i > 0 && i % 3 == 0 {
            result.push(',');
        }
        result.push(c);
    }
    result.chars().rev().collect()
}

fn format_pct(pct: f64) -> String {
    format!("{:.1}%", pct)
}

fn format_bytes(bytes: u64) -> String {
    if bytes >= 1_073_741_824 {
        format!("{:.1} GB", bytes as f64 / 1_073_741_824.0)
    } else if bytes >= 1_048_576 {
        format!("{:.1} MB", bytes as f64 / 1_048_576.0)
    } else if bytes >= 1_024 {
        format!("{:.1} KB", bytes as f64 / 1_024.0)
    } else {
        format!("{} B", bytes)
    }
}

fn format_bytes_per_sec(bps: u64) -> String {
    if bps >= 1_048_576 {
        format!("{:.2} MB/s", bps as f64 / 1_048_576.0)
    } else if bps >= 1_024 {
        format!("{:.2} KB/s", bps as f64 / 1_024.0)
    } else {
        format!("{} B/s", bps)
    }
}

fn new_table() -> Table {
    let mut t = Table::new();
    t.load_preset(UTF8_FULL);
    t.apply_modifier(UTF8_ROUND_CORNERS);
    t.set_content_arrangement(ContentArrangement::Dynamic);
    t
}

// ---------------------------------------------------------------------------
// Report printing
// ---------------------------------------------------------------------------

pub fn print_report(report: &AnalysisReport) {
    print_chain_params(report);
    print_derivation(report);
    print_gas_accounting(report);
    print_throughput(report);
}

fn print_chain_params(report: &AnalysisReport) {
    let c = &report.chain;
    println!();
    println!("Chain Parameters (derived from revm mainnet context)");
    println!("====================================================");

    let mut t = new_table();
    t.set_header(vec!["Parameter", "Value", "Source"]);
    t.add_row(vec![
        Cell::new("Chain ID"),
        Cell::new(c.chain_id),
        Cell::new("cfg.chain_id"),
    ]);
    t.add_row(vec![
        Cell::new("Block gas limit"),
        Cell::new(format_gas(c.block_gas_limit)),
        Cell::new("block.gas_limit"),
    ]);
    t.add_row(vec![
        Cell::new("Base fee"),
        Cell::new(format!("{} gwei", c.basefee)),
        Cell::new("block.basefee"),
    ]);
    t.add_row(vec![
        Cell::new("Intrinsic tx cost"),
        Cell::new(format_gas(c.intrinsic_tx_gas)),
        Cell::new("tx_base_stipend"),
    ]);
    t.add_row(vec![
        Cell::new("Calldata token cost"),
        Cell::new(c.calldata_token_cost),
        Cell::new("tx_token_cost"),
    ]);
    t.add_row(vec![
        Cell::new("Nonzero byte multiplier"),
        Cell::new(c.calldata_nonzero_multiplier),
        Cell::new("tx_token_non_zero_byte_multiplier"),
    ]);
    t.add_row(vec![
        Cell::new("Effective cost/nonzero byte"),
        Cell::new(format!(
            "{} gas ({} x {})",
            c.standard_gas_per_nonzero_byte(),
            c.calldata_token_cost,
            c.calldata_nonzero_multiplier,
        )),
        Cell::new("derived"),
    ]);
    t.add_row(vec![
        Cell::new("EIP-7623 floor per token"),
        Cell::new(c.eip7623_floor_per_token),
        Cell::new("tx_floor_cost_per_token"),
    ]);
    t.add_row(vec![
        Cell::new("EIP-7623 floor base"),
        Cell::new(format_gas(c.eip7623_floor_base)),
        Cell::new("tx_floor_cost_base_gas"),
    ]);
    t.add_row(vec![
        Cell::new("Effective floor/nonzero byte"),
        Cell::new(format!(
            "{} gas ({} x {})",
            c.floor_gas_per_nonzero_byte(),
            c.eip7623_floor_per_token,
            c.calldata_nonzero_multiplier,
        )),
        Cell::new("derived"),
    ]);
    t.add_row(vec![
        Cell::new("Memory quadratic divisor"),
        Cell::new(c.memory_quadratic_divisor),
        Cell::new("memory_quadratic_reduction"),
    ]);
    t.add_row(vec![
        Cell::new("KECCAK256 per-word cost"),
        Cell::new(c.keccak256_per_word),
        Cell::new("keccak256_per_word"),
    ]);
    println!("{t}");

    // Transaction limits
    let tx = &c.tx_limits;
    println!();
    println!("Transaction Limits");
    println!("==================");

    let mut t = new_table();
    t.set_header(vec!["Limit", "Value"]);
    t.add_row(vec![
        Cell::new("Tx gas limit"),
        Cell::new(format_gas(tx.tx_gas_limit)),
    ]);
    t.add_row(vec![
        Cell::new("Max tx size (RLP-encoded)"),
        Cell::new(match tx.max_tx_bytes {
            Some(n) => format!("{} ({})", format_gas(n as u64), format_bytes(n as u64)),
            None => "none".to_string(),
        }),
    ]);
    t.add_row(vec![
        Cell::new("RLP envelope overhead"),
        Cell::new(format!("{} bytes", tx.rlp_envelope_bytes)),
    ]);
    t.add_row(vec![
        Cell::new("Effective max calldata"),
        Cell::new(match tx.max_calldata_bytes() {
            Some(n) => format!("{} ({})", format_gas(n as u64), format_bytes(n as u64)),
            None => "none (gas-limited only)".to_string(),
        }),
    ]);
    println!("{t}");
}

fn print_derivation(report: &AnalysisReport) {
    let d = &report.derivation;
    println!();
    println!("Max Payload Derivation");
    println!("======================");
    println!();
    println!(
        "  Block gas limit:             {}",
        format_gas(d.tx_gas_limit)
    );
    println!(
        "  - Intrinsic:                 {}",
        format_gas(d.intrinsic_gas)
    );
    println!(
        "  - Est. execution:            ~{}",
        format_gas(d.estimated_execution_gas)
    );
    println!();
    println!("  Standard gas pricing:");
    println!(
        "    Calldata budget:           {} gas",
        format_gas(d.standard_calldata_budget_gas)
    );
    println!(
        "    / {} gas/nonzero byte    = {} bytes",
        d.standard_gas_per_byte,
        format_gas(d.standard_max_bytes)
    );
    println!();
    println!("  EIP-7623 floor pricing:");
    println!(
        "    Floor budget:              {} gas",
        format_gas(d.floor_calldata_budget_gas)
    );
    println!(
        "    / {} gas/nonzero byte   = {} bytes",
        d.floor_gas_per_byte,
        format_gas(d.floor_max_bytes)
    );
    if let Some(max_tx) = d.max_tx_bytes {
        println!();
        println!("  Tx size limit:");
        println!(
            "    Max RLP-encoded tx:        {} ({})",
            format_gas(max_tx as u64),
            format_bytes(max_tx as u64)
        );
        println!(
            "    - RLP overhead:            {} bytes",
            d.rlp_envelope_bytes
        );
        if let Some(calldata_cap) = d.max_calldata_bytes_limit {
            println!(
                "    = Max calldata:            {} ({})",
                format_gas(calldata_cap as u64),
                format_bytes(calldata_cap as u64)
            );
        }
    }

    // Ceilings summary table
    println!();
    let mut t = new_table();
    t.set_header(vec!["Constraint", "Max calldata", ""]);
    for c in &d.ceilings {
        let marker = if c.binding { "BINDING" } else { "" };
        t.add_row(vec![
            Cell::new(&c.name),
            Cell::new(format!(
                "{} ({})",
                format_gas(c.max_calldata_bytes),
                format_bytes(c.max_calldata_bytes)
            )),
            Cell::new(marker)
                .fg(if c.binding { Color::Red } else { Color::Reset })
                .add_attribute(if c.binding {
                    Attribute::Bold
                } else {
                    Attribute::Reset
                }),
        ]);
    }
    println!("{t}");

    println!();
    println!(
        "  ABI encoding overhead:       {} bytes",
        format_gas(d.abi_overhead_bytes as u64)
    );
    println!(
        "  Max payload:                 {} ({})",
        format_gas(d.max_payload_bytes as u64),
        format_bytes(d.max_payload_bytes as u64)
    );
}

fn print_gas_accounting(report: &AnalysisReport) {
    let g = &report.gas;
    // Summary
    println!();
    println!("Transaction Cost");
    println!("================");

    let mut summary = new_table();
    summary.set_header(vec!["Component", "Gas", "% of Tx"]);
    summary.add_row(vec![
        Cell::new("Intrinsic"),
        Cell::new(format_gas(g.intrinsic)),
        Cell::new(format_pct(pct(g.intrinsic, g.total))),
    ]);
    let calldata_label = if g.floor_pricing {
        format!(
            "Calldata ({:.1} gas/byte, floor pricing)",
            g.effective_gas_per_nonzero_byte
        )
    } else {
        format!(
            "Calldata ({:.0} gas/byte)",
            g.effective_gas_per_nonzero_byte
        )
    };
    summary.add_row(vec![
        Cell::new(calldata_label),
        Cell::new(format_gas(g.calldata)),
        Cell::new(format_pct(pct(g.calldata, g.total))),
    ]);
    summary.add_row(vec![
        Cell::new("Execution"),
        Cell::new(format_gas(g.execution)),
        Cell::new(format_pct(pct(g.execution, g.total))),
    ]);
    summary.add_row(vec![
        Cell::new("Total").add_attribute(Attribute::Bold),
        Cell::new(format_gas(g.total)).add_attribute(Attribute::Bold),
        Cell::new(format!(
            "{} of block",
            format_pct(g.block_utilisation_pct)
        )),
    ]);
    println!("{summary}");

    // Calldata breakdown
    println!();
    println!("Calldata Breakdown");
    println!("==================");

    let mut cd = new_table();
    cd.set_header(vec!["Section", "Field", "Bytes", "Tokens", "Standard", "Floor", "Effective", "% of Tx"]);
    cd.add_row(vec![
        Cell::new("Intrinsic").add_attribute(Attribute::Bold),
        Cell::new(""), Cell::new(""), Cell::new(""),
        Cell::new(format_gas(g.intrinsic)),
        Cell::new(format_gas(g.intrinsic)),
        Cell::new(format_gas(g.intrinsic)),
        Cell::new(format_pct(pct(g.intrinsic, g.total))),
    ]);
    let mut total_tokens: u64 = 0;
    let mut total_standard: u64 = g.intrinsic;
    let mut total_floor: u64 = g.intrinsic;
    for section in &report.calldata_breakdown {
        let bytes_col = if section.name.starts_with("Payload") {
            format!(
                "{} ({} nz, {} z)",
                format_gas(section.bytes as u64),
                format_gas(section.nonzero_bytes as u64),
                format_gas(section.zero_bytes as u64),
            )
        } else {
            format_gas(section.bytes as u64)
        };
        cd.add_row(vec![
            Cell::new(&section.name).add_attribute(Attribute::Bold),
            Cell::new(""),
            Cell::new(bytes_col),
            Cell::new(format_gas(section.tokens)),
            Cell::new(format_gas(section.standard_gas)),
            Cell::new(format_gas(section.floor_gas)),
            Cell::new(format_gas(section.effective_gas)),
            Cell::new(format_pct(pct(section.effective_gas, g.total))),
        ]);
        total_tokens += section.tokens;
        total_standard += section.standard_gas;
        total_floor += section.floor_gas;
        for field in &section.fields {
            cd.add_row(vec![
                Cell::new(""),
                Cell::new(&field.name),
                Cell::new(format_gas(field.bytes as u64)),
                Cell::new(format_gas(field.tokens)),
                Cell::new(format_gas(field.standard_gas)),
                Cell::new(format_gas(field.floor_gas)),
                Cell::new(format_gas(field.effective_gas)),
                Cell::new(format_pct(pct(field.effective_gas, g.total))),
            ]);
        }
    }
    // Floor total includes floor_base which is shared, not per-section.
    let floor_total = report.chain.eip7623_floor_base
        + total_tokens * report.chain.eip7623_floor_per_token;
    cd.add_row(vec![
        Cell::new("Total").add_attribute(Attribute::Bold),
        Cell::new(""),
        Cell::new(""),
        Cell::new(format_gas(total_tokens)).add_attribute(Attribute::Bold),
        Cell::new(format_gas(total_standard)),
        Cell::new(format_gas(floor_total)),
        Cell::new(format_gas(g.intrinsic + g.calldata)).add_attribute(Attribute::Bold),
        Cell::new(format_pct(pct(g.intrinsic + g.calldata, g.total))),
    ]);
    println!("{cd}");

    // Execution breakdown
    println!();
    println!("Execution Breakdown");
    println!("===================");

    let mut ex = new_table();
    ex.set_header(vec!["Category", "Opcode", "Gas", "% of Execution", "% of Tx"]);
    for cat in &report.categories {
        ex.add_row(vec![
            Cell::new(&cat.name).add_attribute(Attribute::Bold),
            Cell::new(""),
            Cell::new(format_gas(cat.gas)),
            Cell::new(format_pct(cat.pct_of_execution)),
            Cell::new(format_pct(cat.pct_of_tx)),
        ]);
        for op in &cat.opcodes {
            ex.add_row(vec![
                Cell::new(""),
                Cell::new(&op.opcode),
                Cell::new(format_gas(op.gas)),
                Cell::new(format_pct(op.pct_of_execution)),
                Cell::new(format_pct(op.pct_of_tx)),
            ]);
        }
    }
    ex.add_row(vec![
        Cell::new("Total").add_attribute(Attribute::Bold),
        Cell::new(""),
        Cell::new(format_gas(g.execution)).add_attribute(Attribute::Bold),
        Cell::new("100.0%"),
        Cell::new(format_pct(pct(g.execution, g.total))),
    ]);
    println!("{ex}");
}

fn print_throughput(report: &AnalysisReport) {
    let tp = &report.throughput;
    println!();
    println!("Throughput");
    println!("==========");
    println!();
    println!(
        "  Payload per tx:              {}",
        format_bytes(tp.payload_bytes_per_tx as u64)
    );
    println!("  Txs per block:               {}", tp.txs_per_block);
    println!(
        "  Payload per block:           {}",
        format_bytes(tp.payload_bytes_per_block)
    );
    println!();

    let mut t = new_table();
    t.set_header(vec!["Block time", "Txs/sec", "Throughput/sec"]);
    for rate in &tp.rates {
        t.add_row(vec![
            Cell::new(format!("{}s", rate.block_time_secs)),
            Cell::new(format!("{:.1}", rate.txs_per_second)),
            Cell::new(format_bytes_per_sec(rate.payload_bytes_per_second)),
        ]);
    }
    println!("{t}");
}

// ---------------------------------------------------------------------------
// JSON export
// ---------------------------------------------------------------------------

pub fn write_json(report: &AnalysisReport, path: impl AsRef<Path>) -> Result<()> {
    let json = serde_json::to_string_pretty(report)?;
    std::fs::write(path, json)?;
    Ok(())
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn pct(part: u64, total: u64) -> f64 {
    if total > 0 {
        (part as f64 / total as f64) * 100.0
    } else {
        0.0
    }
}
