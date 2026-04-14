mod artifact;
mod profiler;
mod report;
mod scenario;

use eyre::Result;

fn main() -> Result<()> {
    let artifact = artifact::load_artifact()?;

    let scenarios = scenario::build_all();
    println!("Running {} scenarios...\n", scenarios.len());

    let mut results = Vec::new();
    for s in &scenarios {
        let result = profiler::run(&artifact, s)?;
        report::print_row(&result);
        results.push(result);
    }

    report::write_json(&results, "gas-report.json")?;
    println!("\nWrote gas-report.json");

    Ok(())
}
