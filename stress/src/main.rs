mod abi;
mod accounts;
mod config;
mod metrics;
mod runner;
mod workloads;

use clap::Parser;
use config::{Cli, Command, OutputFormat};

#[tokio::main]
async fn main() -> eyre::Result<()> {
    let cli = Cli::parse();

    match cli.command {
        Command::Run(args) => {
            let report = runner::run(&args).await?;

            match args.output {
                OutputFormat::Table => metrics::print_table(&report),
                OutputFormat::Json => {
                    println!("{}", serde_json::to_string_pretty(&report)?);
                }
            }
        }
    }

    Ok(())
}
