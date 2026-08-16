//! The bisect verb: find the dependency commit that first breaks a build or
//! spot predicate.

use std::path::{Path, PathBuf};

use crate::ci::types::{Case, ParsedRequest, Request};
use crate::nix::bisect::{self, Outcome};
use crate::support::error::{request_error, Result};
use crate::support::process::CommandStatus;
use crate::support::ui;

#[derive(clap::Args)]
pub struct BisectArgs {
    /// Revision-capable update target, e.g. wasix-libc or wasmer
    pub target: String,
    /// Known passing ref, or `pinned` for the current pin
    #[arg(long)]
    pub good: String,
    /// Known failing ref, or `pinned` for the current pin
    #[arg(long)]
    pub bad: String,
    /// Follow only the first parent of merge commits
    #[arg(long)]
    pub first_parent: bool,
    /// Keep bisect state and candidate runs here
    #[arg(long)]
    pub run_dir: Option<PathBuf>,
    /// The build or spot command used as the pass/fail predicate
    #[arg(required = true, trailing_var_arg = true, value_name = "PREDICATE")]
    pub command: Vec<String>,
}

/// The predicate as a request. It re-enters the trusted case grammar (the
/// same parser diff cases use), so bisect grows no second command language
/// and a predicate may name a placement.
fn predicate(words: &[String], dependency_target: &str) -> Result<ParsedRequest> {
    let request = match super::request::parse_case(words, None)? {
        Case::Build(build) => Request::Build(build),
        Case::Spot(spot) => Request::Spot(spot),
    };
    if request.cases().iter().any(|case| {
        case.overrides()
            .iter()
            .any(|over| over.target == dependency_target)
    }) {
        return request_error(format!(
            "bisect owns the {dependency_target} override; remove it from the predicate command"
        ));
    }
    Ok(request)
}

pub fn run_bisect(repo: &Path, args: BisectArgs) -> Result<CommandStatus> {
    let dependency = bisect::dependency(repo, &args.target)?;

    let words: Vec<String> = args
        .command
        .iter()
        .skip_while(|word| *word == "--")
        .cloned()
        .collect();
    // Parse once up front so a broken predicate fails before the first
    // candidate builds.
    predicate(&words, &dependency.target)?;

    let run_dir = match &args.run_dir {
        Some(dir) => dir.clone(),
        None => {
            let base = crate::support::env::temp_dir().join("wasinix-bisect");
            crate::support::fs::create_dir_all(&base)?;
            base.join(format!(
                "{}-{}",
                std::process::id(),
                crate::support::time::unix_secs()
            ))
        }
    };

    let target = dependency.target.clone();
    let report = bisect::run(
        bisect::Options {
            dependency,
            good: args.good,
            bad: args.bad,
            first_parent: args.first_parent,
            command: words.clone(),
            run_dir: run_dir.clone(),
        },
        |rev, candidate_dir| {
            let mut request = predicate(&words, &target)?;
            super::request::with_override(&mut request, &target, rev);
            crate::support::fs::create_dir_all(candidate_dir)?;
            let status = super::request::drive(super::request::Drive {
                repo,
                source: super::request::Source::Parse {
                    request,
                    origin: None,
                },
                run_dir: candidate_dir.to_path_buf(),
                trusted_refs: &[],
                cache: super::request::CacheIntent::Off,
                only: super::request::TaskFilter::All,
                follow: false,
                finish: super::request::Finish::Silent,
            })?;
            Ok(if status.is_success() {
                Outcome::Good
            } else {
                Outcome::Bad
            })
        },
    )?;

    match &report.first_bad {
        Some(rev) => {
            ui::result(format!("first bad {} commit: {rev}", report.target));
        }
        None => ui::result(format!("{}: no first-bad commit found", report.target)),
    }
    ui::fact("report", run_dir.join(bisect::REPORT_FILE).display());
    Ok(CommandStatus::SUCCESS)
}
