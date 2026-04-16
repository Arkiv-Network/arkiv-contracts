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

fn format_duration(secs: f64) -> String {
    if secs < 60.0 {
        format!("{:.0}s", secs)
    } else if secs < 3600.0 {
        let m = (secs / 60.0).floor();
        let s = secs % 60.0;
        format!("{:.0}m {:.0}s", m, s)
    } else if secs < 86400.0 {
        let h = (secs / 3600.0).floor();
        let m = ((secs % 3600.0) / 60.0).floor();
        format!("{:.0}h {:.0}m", h, m)
    } else {
        let d = (secs / 86400.0).floor();
        let h = ((secs % 86400.0) / 3600.0).floor();
        format!("{:.0}d {:.0}h", d, h)
    }
}

fn format_usd(usd: f64) -> String {
    if usd >= 1.0 {
        format!("${:.2}", usd)
    } else if usd >= 0.01 {
        format!("${:.4}", usd)
    } else {
        format!("${:.6}", usd)
    }
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
    print_gas_accounting(report);
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
    let ch = &report.chain;

    // Execution breakdown (before calldata, since floor dominates calldata cost
    // and execution is only relevant relative to standard pricing).
    let total_tokens: u64 = report.calldata_breakdown.iter().map(|s| s.tokens).sum();
    let standard_calldata = total_tokens * ch.calldata_token_cost;
    let standard_plus_exec = ch.intrinsic_tx_gas + standard_calldata + g.execution;

    println!();
    println!("Execution Breakdown");
    println!("===================");
    println!();
    println!(
        "  Execution gas: {} ({:.1}% of standard + execution = {})",
        format_gas(g.execution),
        pct(g.execution, standard_plus_exec),
        format_gas(standard_plus_exec),
    );
    println!();

    let mut ex = new_table();
    ex.set_header(vec![
        "Category", "Opcode", "Gas", "% of Execution",
        &format!("% of Std+Exec ({})", format_gas(standard_plus_exec)),
    ]);
    for cat in &report.categories {
        ex.add_row(vec![
            Cell::new(&cat.name).add_attribute(Attribute::Bold),
            Cell::new(""),
            Cell::new(format_gas(cat.gas)),
            Cell::new(format_pct(cat.pct_of_execution)),
            Cell::new(format_pct(pct(cat.gas, standard_plus_exec))),
        ]);
        for op in &cat.opcodes {
            ex.add_row(vec![
                Cell::new(""),
                Cell::new(&op.opcode),
                Cell::new(format_gas(op.gas)),
                Cell::new(format_pct(op.pct_of_execution)),
                Cell::new(format_pct(pct(op.gas, standard_plus_exec))),
            ]);
        }
    }
    ex.add_row(vec![
        Cell::new("Total").add_attribute(Attribute::Bold),
        Cell::new(""),
        Cell::new(format_gas(g.execution)).add_attribute(Attribute::Bold),
        Cell::new("100.0%"),
        Cell::new(format_pct(pct(g.execution, standard_plus_exec))),
    ]);
    println!("{ex}");

    // Calldata breakdown
    println!();
    println!("Calldata Breakdown");
    println!("==================");

    let mut cd = new_table();
    cd.set_header(vec!["Section", "Field", "Bytes", "Zero", "Nonzero", "Tokens In Calldata", "Gas (Standard)", "Gas (Floor)"]);

    let cd_row = |name: Cell, field: &str, s: &gas_profiler_lib::analysis::CalldataSection| -> Vec<Cell> {
        vec![
            name,
            Cell::new(field),
            Cell::new(format_gas(s.bytes as u64)),
            Cell::new(format_gas(s.zero_bytes as u64)),
            Cell::new(format_gas(s.nonzero_bytes as u64)),
            Cell::new(format_gas(s.tokens)),
            Cell::new(format_gas(s.standard_gas)),
            Cell::new(format_gas(s.floor_gas)),
        ]
    };

    let mut cd_total_tokens: u64 = 0;
    let mut cd_total_standard: u64 = 0;
    let mut cd_total_floor: u64 = 0;
    for section in &report.calldata_breakdown {
        cd.add_row(cd_row(
            Cell::new(&section.name).add_attribute(Attribute::Bold),
            "",
            section,
        ));
        cd_total_tokens += section.tokens;
        cd_total_standard += section.standard_gas;
        cd_total_floor += section.floor_gas;
        for field in &section.fields {
            cd.add_row(cd_row(Cell::new(""), &field.name, field));
            // Third level: struct fields within attributes.
            for sub in &field.fields {
                cd.add_row(vec![
                    Cell::new(""),
                    Cell::new(format!("  {}", sub.name)),
                    Cell::new(format_gas(sub.bytes as u64)),
                    Cell::new(""), Cell::new(""),
                    Cell::new(format_gas(sub.tokens)),
                    Cell::new(format_gas(sub.standard_gas)),
                    Cell::new(format_gas(sub.floor_gas)),
                    Cell::new(""),
                    Cell::new(""),
                ]);
            }
        }
    }
    let cd_floor_total = ch.eip7623_floor_base + cd_total_tokens * ch.eip7623_floor_per_token;
    let cd_total_bytes: usize = report.calldata_breakdown.iter().map(|s| s.bytes).sum();
    let cd_total_zero: usize = report.calldata_breakdown.iter().map(|s| s.zero_bytes).sum();
    let cd_total_nz: usize = report.calldata_breakdown.iter().map(|s| s.nonzero_bytes).sum();
    cd.add_row(vec![
        Cell::new("Total").add_attribute(Attribute::Bold),
        Cell::new(""),
        Cell::new(format_gas(cd_total_bytes as u64)).add_attribute(Attribute::Bold),
        Cell::new(format_gas(cd_total_zero as u64)),
        Cell::new(format_gas(cd_total_nz as u64)),
        Cell::new(format_gas(cd_total_tokens)).add_attribute(Attribute::Bold),
        Cell::new(format_gas(cd_total_standard)),
        Cell::new(format_gas(cd_floor_total)),
    ]);
    cd.add_row(vec![
        Cell::new("+ Intrinsic (21,000)").add_attribute(Attribute::Bold),
        Cell::new(""), Cell::new(""), Cell::new(""), Cell::new(""), Cell::new(""),
        Cell::new(format_gas(cd_total_standard + g.intrinsic)).add_attribute(Attribute::Bold),
        Cell::new(format_gas(cd_floor_total + g.intrinsic)).add_attribute(Attribute::Bold),
    ]);
    println!("{cd}");

    // Gas calculation per EIP-7623
    //
    // tokens_in_calldata = zero_bytes + nonzero_bytes * 4
    // tx.gasUsed = 21000 + max(
    //     STANDARD_TOKEN_COST * tokens + execution_gas,     ← standard
    //     TOTAL_COST_FLOOR_PER_TOKEN * tokens               ← floor
    // )
    let standard_inner = cd_total_tokens * ch.calldata_token_cost + g.execution;
    let floor_inner = cd_total_tokens * ch.eip7623_floor_per_token;

    println!();
    println!("  EIP-7623 gas calculation:");
    println!();
    println!("    tokens_in_calldata = zero_bytes + nonzero_bytes * {}",
        ch.calldata_nonzero_multiplier);
    println!("                       = {} + {} * {} = {}",
        format_gas(cd_total_zero as u64),
        format_gas(cd_total_nz as u64),
        ch.calldata_nonzero_multiplier,
        format_gas(cd_total_tokens));
    println!();
    println!("    tx.gasUsed = 21000 + max(");
    println!("        STANDARD_TOKEN_COST * tokens + execution_gas,");
    println!("        TOTAL_COST_FLOOR_PER_TOKEN * tokens");
    println!("    )");
    println!();
    println!("    standard: {} * {} + {} = {}",
        ch.calldata_token_cost,
        format_gas(cd_total_tokens),
        format_gas(g.execution),
        format_gas(standard_inner));
    println!("    floor:    {} * {} = {}",
        ch.eip7623_floor_per_token,
        format_gas(cd_total_tokens),
        format_gas(floor_inner));
    println!();
    println!("    tx.gasUsed = {} + max({}, {}) = {} + {} = {}",
        format_gas(ch.intrinsic_tx_gas),
        format_gas(standard_inner),
        format_gas(floor_inner),
        format_gas(ch.intrinsic_tx_gas),
        format_gas(standard_inner.max(floor_inner)),
        format_gas(ch.intrinsic_tx_gas + standard_inner.max(floor_inner)));
    if g.floor_pricing {
        println!();
        println!("    Floor branch wins. Standard + execution ({}) < floor ({}).",
            format_gas(standard_inner),
            format_gas(floor_inner));
        println!("    Floor adds {} gas ({:.1}%) over the standard branch.",
            format_gas(floor_inner.saturating_sub(standard_inner)),
            pct(floor_inner.saturating_sub(standard_inner), standard_inner));
    }

    // Cost matrix: gas price tiers × ETH price tiers, for both standard and floor
    let gas_prices_gwei: &[(u64, &str)] = &[(5, "Low"), (20, "Med"), (50, "High")];
    let eth_prices_usd: &[(f64, &str)] = &[(1_500.0, "$1,500"), (2_500.0, "$2,500"), (4_000.0, "$4,000")];

    let standard_gas_used = ch.intrinsic_tx_gas + standard_inner;
    let floor_gas_used = ch.intrinsic_tx_gas + floor_inner;

    for &(label, gas_used) in &[
        ("Standard", standard_gas_used),
        ("Floor (EIP-7623)", floor_gas_used),
    ] {
        println!();
        println!("Transaction Cost — {} ({} gas)", label, format_gas(gas_used));
        let mut cost = new_table();
        let mut header = vec!["Gas Price".to_string(), "ETH".to_string()];
        for &(_, eth_label) in eth_prices_usd {
            header.push(eth_label.to_string());
        }
        cost.set_header(header);

        for &(gas_gwei, gas_label) in gas_prices_gwei {
            let eth_cost = gas_used as f64 * gas_gwei as f64 * 1e-9;
            let mut row = vec![
                Cell::new(format!("{} ({} gwei)", gas_label, gas_gwei)),
                Cell::new(format!("{:.6} ETH", eth_cost)),
            ];
            for &(eth_price, _) in eth_prices_usd {
                row.push(Cell::new(format_usd(eth_cost * eth_price)));
            }
            cost.add_row(row);
        }
        println!("{cost}");
    }

    // Throughput
    let payload_kb = g.total as f64; // reuse gas for tx count calc
    let payload_bytes = report.calldata_breakdown.iter()
        .find(|s| s.name == "Payload")
        .map(|s| s.bytes)
        .unwrap_or(0);
    let payload_kb_f = payload_bytes as f64 / 1024.0;

    // For both standard and floor gas
    println!();
    println!("Throughput");
    println!("==========");
    println!();
    println!("  Payload per tx: {:.1} KB ({} bytes)", payload_kb_f, format_gas(payload_bytes as u64));
    println!();

    let block_gas_limits: &[(u64, &str)] = &[
        (30_000_000, "30M"),
        (60_000_000, "60M"),
    ];

    let mut tp = new_table();
    tp.set_header(vec!["", "Block Gas", "Txs/Block", "KB/Block", "KB/s (L2 2s)", "KB/s (L1 12s)"]);

    for &(label, gas_used) in &[
        ("Standard", standard_gas_used),
        ("Floor (EIP-7623)", floor_gas_used),
    ] {
        for &(block_gas, block_label) in block_gas_limits {
            let txs_per_block = block_gas / gas_used;
            let kb_per_block = txs_per_block as f64 * payload_kb_f;

            tp.add_row(vec![
                Cell::new(format!("{} ({})", label, block_label)).add_attribute(Attribute::Bold),
                Cell::new(format_gas(block_gas)),
                Cell::new(txs_per_block),
                Cell::new(format!("{:.1}", kb_per_block)),
                Cell::new(format!("{:.1}", kb_per_block / 2.0)),
                Cell::new(format!("{:.1}", kb_per_block / 12.0)),
            ]);
        }
    }
    println!("{tp}");

    // Cost per unit of data and time to write, at medium gas / medium ETH
    let mid_gas_gwei = 20u64;
    let mid_eth_usd = 2_500.0f64;

    println!();
    println!("Data Cost (@ {} gwei, ETH ${})", mid_gas_gwei, format_gas(mid_eth_usd as u64));
    println!();

    let mut dc = new_table();
    dc.set_header(vec!["", "$/KB", "$/MB", "$/GB",
        "1 GB @ 1s", "1 GB @ 2s (L2)", "1 GB @ 12s (L1)"]);

    for &(label, gas_used) in &[
        ("Standard", standard_gas_used),
        ("Floor (EIP-7623)", floor_gas_used),
    ] {
        let cost_per_tx = gas_used as f64 * mid_gas_gwei as f64 * 1e-9 * mid_eth_usd;
        let cost_per_kb = cost_per_tx / payload_kb_f;
        let cost_per_mb = cost_per_kb * 1024.0;
        let cost_per_gb = cost_per_mb * 1024.0;
        let gb_in_kb = 1024.0 * 1024.0;

        for &(block_gas, block_label) in block_gas_limits {
            let txs_per_block = block_gas / gas_used;
            let kb_per_block = txs_per_block as f64 * payload_kb_f;
            let blocks_for_gb = (gb_in_kb / kb_per_block).ceil();

            dc.add_row(vec![
                Cell::new(format!("{} ({})", label, block_label)).add_attribute(Attribute::Bold),
                Cell::new(format_usd(cost_per_kb)),
                Cell::new(format_usd(cost_per_mb)),
                Cell::new(format_usd(cost_per_gb)),
                Cell::new(format_duration(blocks_for_gb * 1.0)),
                Cell::new(format_duration(blocks_for_gb * 2.0)),
                Cell::new(format_duration(blocks_for_gb * 12.0)),
            ]);
        }
    }
    println!("{dc}");
    println!();
    println!("  Note: costs assume a flat gas price per transaction. In practice, filling");
    println!("  blocks with large calldata-heavy transactions would increase gas prices via");
    println!("  the EIP-1559 base fee auction mechanism. Sustained max-throughput writes");
    println!("  would drive base fees significantly higher than the {} gwei assumed here.", mid_gas_gwei);

}

fn print_operation_detail(report: &AnalysisReport) {
    println!();
    println!("Operation Fields");
    println!("================");

    for f in &report.operation_detail {
        println!();
        println!(
            "  {} ({}) = {}  [{} bytes, {} tokens, std {} / floor {} gas]",
            f.name, f.abi_type, f.value_display,
            f.bytes, format_gas(f.tokens),
            format_gas(f.standard_gas), format_gas(f.floor_gas),
        );
        for (i, word) in f.words.iter().enumerate() {
            println!("    word[{}]: {}", i, word);
        }
    }
}

fn print_attribute_detail(report: &AnalysisReport) {
    println!();
    println!("Attributes");
    println!("==========");

    for attr in &report.attribute_detail {
        println!();
        println!(
            "  [{}] {} ({}) = {}  [{} bytes, {} tokens, std {} / floor {} gas]",
            attr.index, attr.name_label, attr.value_type_label, attr.value_display,
            attr.bytes, format_gas(attr.tokens),
            format_gas(attr.standard_gas), format_gas(attr.floor_gas),
        );
        println!();
        println!("    name (bytes32):");
        println!("      {}", attr.name_hex);
        println!("    valueType (uint8 = {}):", attr.value_type);
        println!("      {}", attr.value_type_hex);
        println!("    value (bytes32[4]):");
        for slot in &attr.value_slots {
            println!("      {}", slot);
        }
    }
}

fn print_payload_detail(report: &AnalysisReport) {
    let p = &report.payload_detail;
    println!();
    println!("Payload");
    println!("=======");
    println!();

    let mut t = new_table();
    t.set_header(vec!["", "Bytes", "Tokens", "Standard", "Floor"]);
    t.add_row(vec![
        Cell::new("Nonzero bytes").add_attribute(Attribute::Bold),
        Cell::new(format_gas(p.nonzero_bytes as u64)),
        Cell::new(format_gas(p.nonzero_tokens)),
        Cell::new(format_gas(p.nonzero_tokens * report.chain.calldata_token_cost)),
        Cell::new(format_gas(p.nonzero_tokens * report.chain.eip7623_floor_per_token)),
    ]);
    t.add_row(vec![
        Cell::new("Zero bytes"),
        Cell::new(format_gas(p.zero_bytes as u64)),
        Cell::new(format_gas(p.zero_tokens)),
        Cell::new(format_gas(p.zero_tokens * report.chain.calldata_token_cost)),
        Cell::new(format_gas(p.zero_tokens * report.chain.eip7623_floor_per_token)),
    ]);
    t.add_row(vec![
        Cell::new("Total").add_attribute(Attribute::Bold),
        Cell::new(format_gas(p.total_bytes as u64)),
        Cell::new(format_gas(p.total_tokens)),
        Cell::new(format_gas(p.standard_gas)),
        Cell::new(format_gas(p.floor_gas)),
    ]);
    println!("{t}");

    println!();
    println!("  Head (first 64 bytes):");
    for line in p.head_hex.as_bytes().chunks(64) {
        println!("    {}", std::str::from_utf8(line).unwrap_or(""));
    }
    println!("  Tail (last 64 bytes):");
    for line in p.tail_hex.as_bytes().chunks(64) {
        println!("    {}", std::str::from_utf8(line).unwrap_or(""));
    }
}

fn print_gas_calculation_summary(report: &AnalysisReport) {
    let c = &report.chain;
    let g = &report.gas;

    // Reconstruct the calculation from initial_tx_gas.
    let total_tokens: u64 = report.calldata_breakdown.iter().map(|s| s.tokens).sum();
    let standard_calldata = total_tokens * c.calldata_token_cost;
    let standard_total = c.intrinsic_tx_gas + standard_calldata;
    let floor_total = c.eip7623_floor_base + total_tokens * c.eip7623_floor_per_token;

    println!();
    println!("Calldata Gas Calculation");
    println!("========================");
    println!();
    println!("  The EVM prices calldata using a token model (revm: GasParams::initial_tx_gas).");
    println!("  Each calldata byte is converted to tokens:");
    println!();
    println!(
        "    Zero byte:    1 token                  (tx_token_non_zero_byte_multiplier irrelevant)"
    );
    println!(
        "    Nonzero byte: {} tokens                 (tx_token_non_zero_byte_multiplier = {})",
        c.calldata_nonzero_multiplier, c.calldata_nonzero_multiplier
    );
    println!();
    println!("  Total calldata tokens = zero_bytes x 1 + nonzero_bytes x {}", c.calldata_nonzero_multiplier);
    println!("                        = {} tokens", format_gas(total_tokens));
    println!();
    println!("  Standard gas calculation:");
    println!("    initial_total_gas = tokens x tx_token_cost + tx_base_stipend");
    println!(
        "                      = {} x {} + {}",
        format_gas(total_tokens), c.calldata_token_cost, format_gas(c.intrinsic_tx_gas)
    );
    println!("                      = {} + {}", format_gas(standard_calldata), format_gas(c.intrinsic_tx_gas));
    println!("                      = {}", format_gas(standard_total));
    println!();
    println!("  EIP-7623 floor calculation:");
    println!("    floor_gas = tx_floor_cost_base_gas + tokens x tx_floor_cost_per_token");
    println!(
        "              = {} + {} x {}",
        format_gas(c.eip7623_floor_base), format_gas(total_tokens), c.eip7623_floor_per_token
    );
    println!("              = {}", format_gas(floor_total));
    println!();
    println!("  Actual gas = max(standard + execution, floor)");
    println!(
        "             = max({} + {}, {})",
        format_gas(standard_total),
        format_gas(g.execution),
        format_gas(floor_total)
    );
    println!(
        "             = max({}, {})",
        format_gas(standard_total + g.execution),
        format_gas(floor_total)
    );
    println!("             = {}", format_gas(g.total));
    if g.floor_pricing {
        println!();
        println!(
            "  Floor pricing is ACTIVE. The floor ({}) exceeds standard + execution ({}).",
            format_gas(floor_total),
            format_gas(standard_total + g.execution),
        );
        println!(
            "  Effective calldata cost is {:.1} gas/nonzero byte vs standard {} gas/nonzero byte.",
            g.effective_gas_per_nonzero_byte,
            c.standard_gas_per_nonzero_byte(),
        );
        println!(
            "  The floor adds {} gas ({:.1}%) over the standard calculation.",
            format_gas(floor_total.saturating_sub(standard_total + g.execution)),
            pct(floor_total.saturating_sub(standard_total + g.execution), standard_total + g.execution),
        );
    } else {
        println!();
        println!(
            "  Standard pricing applies. Floor ({}) < standard + execution ({}).",
            format_gas(floor_total),
            format_gas(standard_total + g.execution),
        );
    }
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
