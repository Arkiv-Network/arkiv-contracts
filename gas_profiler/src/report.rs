use crate::profiler::ProfileResult;
use eyre::Result;
use std::path::Path;

/// Print a single-line summary for a scenario result.
pub fn print_row(r: &ProfileResult) {
    let keccak = r
        .opcode_gas
        .get("SHA3")
        .or_else(|| r.opcode_gas.get("KECCAK256"));
    let sstore = r.opcode_gas.get("SSTORE");
    let sload = r.opcode_gas.get("SLOAD");

    println!("{}", r.scenario);
    println!(
        "  total: {:>9} gas | KECCAK256: {:>7} ({:>5.1}%) {:>3} calls | SSTORE: {:>7} ({:>5.1}%) | SLOAD: {:>7} ({:>5.1}%)",
        r.total_gas,
        keccak.map_or(0, |s| s.gas),
        keccak.map_or(0.0, |s| s.pct),
        keccak.map_or(0, |s| s.count),
        sstore.map_or(0, |s| s.gas),
        sstore.map_or(0.0, |s| s.pct),
        sload.map_or(0, |s| s.gas),
        sload.map_or(0.0, |s| s.pct),
    );
    println!();
}

/// Write all results to a JSON file.
pub fn write_json(results: &[ProfileResult], path: impl AsRef<Path>) -> Result<()> {
    let json = serde_json::to_string_pretty(results)?;
    std::fs::write(path, json)?;
    Ok(())
}
