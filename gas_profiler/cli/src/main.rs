mod artifact;
mod report;

use eyre::Result;
use gas_profiler_lib::{analysis, chain::ChainParams, executor, scenario};

fn main() -> Result<()> {
    // 1. Extract chain parameters from revm's mainnet context.
    let chain = ChainParams::mainnet();

    // 2. Load contract bytecode from forge artifact.
    let init_code = artifact::load_init_code()?;

    // 3. Derive the max-payload CREATE scenario from chain ceilings.
    let (scenario, derivation) = scenario::max_create(&chain);

    // 4. Execute the profiled transaction.
    let trace = executor::execute(&init_code, &scenario, &chain)?;

    // 5. Analyze: full cost breakdown + throughput.
    let report = analysis::analyze(&trace, &chain, derivation, &scenario.calldata, &scenario.attributes);

    // 6. Render.
    report::print_report(&report);
    report::write_json(&report, "gas-report.json")?;
    println!();
    println!("Wrote gas-report.json");

    Ok(())
}
