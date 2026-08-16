//! The orchestrator. A single binary crate: everything is crate-internal, so
//! code no production path reaches fails the build as dead.
#![deny(dead_code)]

mod ci;
mod cli;
mod github;
mod nix;
mod registries;
mod runs;
mod support;
mod update;

#[cfg(test)]
mod tests;

fn main() -> std::process::ExitCode {
    cli::main()
}
