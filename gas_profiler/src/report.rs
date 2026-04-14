use crate::profiler::{OpcodeStats, ProfileResult};
use eyre::Result;
use std::path::Path;

/// Opcode categories for grouped analysis.
const CATEGORIES: &[(&str, &[&str])] = &[
    ("Storage", &["SSTORE", "SLOAD"]),
    ("Hashing", &["KECCAK256"]),
    ("Memory", &["MSTORE", "MSTORE8", "MLOAD", "MCOPY"]),
    ("Calldata", &["CALLDATACOPY", "CALLDATALOAD", "CALLDATASIZE"]),
    ("Logging", &["LOG0", "LOG1", "LOG2", "LOG3", "LOG4"]),
    (
        "Control flow",
        &["JUMP", "JUMPI", "JUMPDEST", "STOP", "RETURN", "REVERT"],
    ),
    (
        "Arithmetic",
        &[
            "ADD", "SUB", "MUL", "DIV", "SDIV", "MOD", "SMOD", "EXP",
            "ADDMOD", "MULMOD", "SIGNEXTEND",
        ],
    ),
    (
        "Comparison / Bitwise",
        &[
            "LT", "GT", "SLT", "SGT", "EQ", "ISZERO", "AND", "OR",
            "XOR", "NOT", "BYTE", "SHL", "SHR", "SAR",
        ],
    ),
    (
        "Stack",
        &[
            "POP", "PUSH0", "PUSH1", "PUSH2", "PUSH4", "PUSH8", "PUSH12",
            "PUSH16", "PUSH20", "PUSH32",
            "DUP1", "DUP2", "DUP3", "DUP4", "DUP5", "DUP6", "DUP7",
            "DUP8", "DUP9", "DUP10", "DUP11", "DUP12", "DUP13", "DUP14",
            "DUP15", "DUP16",
            "SWAP1", "SWAP2", "SWAP3", "SWAP4", "SWAP5", "SWAP6", "SWAP7",
            "SWAP8", "SWAP9", "SWAP10", "SWAP11", "SWAP12", "SWAP13",
            "SWAP14", "SWAP15", "SWAP16",
        ],
    ),
    (
        "Environment",
        &[
            "ADDRESS", "CALLER", "CALLVALUE", "CHAINID", "NUMBER",
            "TIMESTAMP", "GASPRICE", "GASLIMIT", "COINBASE", "DIFFICULTY",
            "BASEFEE", "SELFBALANCE", "GAS",
        ],
    ),
];

/// Print a full analysis for a scenario result.
pub fn print_row(r: &ProfileResult) {
    println!("═══════════════════════════════════════════════════════════════");
    println!("{}", r.scenario);
    println!("═══════════════════════════════════════════════════════════════");
    println!();
    println!("  Transaction gas:  {:>12}", format_gas(r.total_gas));
    println!("  Execution gas:    {:>12}", format_gas(r.execution_gas));
    println!("  Overhead:         {:>12}  (intrinsic 21K + calldata gas)", format_gas(r.overhead_gas));
    println!();
    println!("  All percentages below are relative to execution gas.");
    println!();

    // ── Categorised breakdown ──
    println!("  ── By category ──");
    println!();

    let mut accounted = 0u64;
    for &(category, opcodes) in CATEGORIES {
        let mut cat_gas = 0u64;
        let mut cat_count = 0u64;
        let mut entries: Vec<(&str, &OpcodeStats)> = Vec::new();

        for &op in opcodes {
            if let Some(s) = r.opcode_gas.get(op) {
                cat_gas += s.gas;
                cat_count += s.count;
                entries.push((op, s));
            }
        }

        if cat_gas == 0 {
            continue;
        }

        let cat_pct = if r.execution_gas > 0 {
            (cat_gas as f64 / r.execution_gas as f64) * 100.0
        } else {
            0.0
        };
        println!(
            "  {:<22} {:>12} gas  ({:>5.1}%)  {:>6} ops",
            category,
            format_gas(cat_gas),
            cat_pct,
            cat_count
        );

        // Show individual opcodes within category, sorted by gas desc.
        entries.sort_by(|a, b| b.1.gas.cmp(&a.1.gas));
        for (op, s) in &entries {
            println!(
                "    {:<20} {:>12} gas  ({:>5.1}%)  {:>6} calls",
                op,
                format_gas(s.gas),
                s.pct,
                s.count
            );
        }
        println!();
        accounted += cat_gas;
    }

    // ── Uncategorised opcodes ──
    let uncategorised = r.execution_gas.saturating_sub(accounted);
    if uncategorised > 0 {
        let pct = if r.execution_gas > 0 {
            (uncategorised as f64 / r.execution_gas as f64) * 100.0
        } else {
            0.0
        };
        println!(
            "  {:<22} {:>12} gas  ({:>5.1}%)",
            "Uncategorised",
            format_gas(uncategorised),
            pct
        );
        println!();
    }

    // ── Top opcodes by gas ──
    println!("  ── Top 10 opcodes by gas ──");
    println!();
    let mut all: Vec<(&String, &OpcodeStats)> = r.opcode_gas.iter().collect();
    all.sort_by(|a, b| b.1.gas.cmp(&a.1.gas));
    for (op, s) in all.iter().take(10) {
        println!(
            "    {:<20} {:>12} gas  ({:>5.1}%)  {:>6} calls",
            op,
            format_gas(s.gas),
            s.pct,
            s.count
        );
    }
    println!();
}

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

/// Write all results to a JSON file.
pub fn write_json(results: &[ProfileResult], path: impl AsRef<Path>) -> Result<()> {
    let json = serde_json::to_string_pretty(results)?;
    std::fs::write(path, json)?;
    Ok(())
}
