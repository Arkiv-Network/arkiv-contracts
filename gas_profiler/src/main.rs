mod artifact;
mod profiler;
mod report;
mod scenario;

use eyre::Result;
use profiler::GasSchedule;

fn main() -> Result<()> {
    let artifact = artifact::load_artifact()?;
    let scenarios = scenario::build_all();
    let schedules = [GasSchedule::mainnet(), GasSchedule::optimised()];

    let mut all_results = Vec::new();

    for s in &scenarios {
        let mut scenario_results = Vec::new();

        for sched in &schedules {
            let result = profiler::run(&artifact, s, sched)?;
            scenario_results.push(result);
        }

        // Print each schedule's full breakdown.
        for r in &scenario_results {
            report::print_row(r);
        }

        // Print side-by-side comparison.
        report::print_comparison(&scenario_results[0], &scenario_results[1]);

        all_results.extend(scenario_results);
    }

    report::write_json(&all_results, "gas-report.json")?;
    println!("Wrote gas-report.json");

    Ok(())
}
