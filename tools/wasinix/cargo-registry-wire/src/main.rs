use std::path::PathBuf;

use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(about = "Cargo registry wire helpers for WASIX registry derivations")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Publish a minted .crate through Cargo's registry wire protocol.
    Publish {
        crate_path: PathBuf,
        base_url: String,
        token: String,
    },
    /// Render a mint as a static Cargo sparse index.
    SparseIndex {
        mint: PathBuf,
        output: PathBuf,
        #[arg(long)]
        base_url: String,
        #[arg(long)]
        only: Vec<String>,
    },
}

fn run() -> cargo_registry_wire::Result<()> {
    match Cli::parse().command {
        Command::Publish {
            crate_path,
            base_url,
            token,
        } => {
            let metadata = cargo_registry_wire::read_metadata(&crate_path)?;
            let status = cargo_registry_wire::publish(&crate_path, &base_url, &token)?;
            println!("published {} {} -> {status}", metadata.name, metadata.vers);
        }
        Command::SparseIndex {
            mint,
            output,
            base_url,
            only,
        } => {
            let receipt = cargo_registry_wire::sparse_index(&mint, &output, &base_url, &only)?;
            println!(
                "sparse index: {} entries for {} crates",
                receipt.entries, receipt.crates
            );
        }
    }
    Ok(())
}

fn main() {
    if let Err(error) = run() {
        eprintln!("cargo-registry-wire: {error}");
        std::process::exit(1);
    }
}
