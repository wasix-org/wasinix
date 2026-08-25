//! The bisect verb: find the dependency commit that first breaks a build or
//! spot predicate.

use std::path::{Path, PathBuf};

use crate::ci::report::Conclusion;
use crate::ci::types::{Case, ParsedRequest, Request};
use crate::nix::bisect::{self, Outcome};
use crate::support::atoms::BlockedPolicy;
use crate::support::error::{Result, request_error};
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
    /// Find where the predicate started passing instead: --bad names the
    /// older revision where it fails, --good the newer one where it passes
    #[arg(long)]
    pub reverse: bool,
    /// Keep bisect state and candidate runs here
    #[arg(long)]
    pub run_dir: Option<PathBuf>,
    #[command(flatten)]
    pub outcome: super::OutcomeArgs,
    /// The build or spot command used as the pass/fail predicate
    #[arg(required = true, trailing_var_arg = true, value_name = "PREDICATE")]
    pub command: Vec<String>,
}

/// The predicate as a request. It re-enters the trusted case grammar (the
/// same parser diff cases use), so bisect grows no second command language
/// and a predicate may name a placement.
pub fn predicate(
    words: &[String],
    dependency_target: &str,
    blocked: BlockedPolicy,
    surface: super::Surface,
) -> Result<ParsedRequest> {
    let request = match super::request::parse_case(words, None, surface)? {
        Case::Build(build) => Request::build(build, blocked),
        Case::Spot(spot) => Request::spot(spot, blocked),
    };
    reject_own_override(&request, dependency_target)?;
    Ok(request)
}

/// Bisect supplies the dependency's revision per candidate, so a predicate
/// naming it would silently pin every candidate to one commit.
pub fn reject_own_override(request: &ParsedRequest, dependency_target: &str) -> Result<()> {
    if request.cases().iter().any(|case| {
        case.overrides()
            .iter()
            .any(|over| over.target == dependency_target)
    }) {
        return request_error(format!(
            "bisect owns the {dependency_target} override; remove it from the predicate command"
        ));
    }
    Ok(())
}

/// One bisect to drive: the predicate is already parsed, so an untrusted
/// caller supplies one whose placement it has pinned.
pub struct Bisect<'a> {
    pub target: String,
    pub good: String,
    pub bad: String,
    pub first_parent: bool,
    pub reverse: bool,
    /// The predicate as written, recorded in the report.
    pub words: Vec<String>,
    pub predicate: ParsedRequest,
    pub run_dir: PathBuf,
    pub budget: Option<bisect::Budget>,
    /// Parent stream that should narrate each nested candidate run.
    pub event_parent: Option<PathBuf>,
    /// Called with the candidate count before each build, for a caller whose
    /// answer is hours away and who has somewhere to say so.
    pub progress: Option<&'a mut dyn FnMut(usize) -> Result<()>>,
}

pub(crate) fn candidate_outcome(report: &crate::ci::report::Report) -> Result<Outcome> {
    let conclusion = report.conclusion.ok_or_else(|| {
        crate::support::error::Error::Failure("bisect candidate produced no conclusion".into())
    })?;
    Ok(match conclusion {
        Conclusion::Success => Outcome::Good,
        Conclusion::Failure => Outcome::Bad,
        Conclusion::Neutral => Outcome::Skip,
        Conclusion::Blocked => match report.blocked_policy() {
            BlockedPolicy::Fail => Outcome::Bad,
            BlockedPolicy::Skip => Outcome::Skip,
            BlockedPolicy::Good => Outcome::Good,
        },
    })
}

/// Walk the candidates, building the predicate against each. The report is
/// written after every candidate, so an interrupted or budgeted run resumes
/// from what it already knows.
pub fn drive(repo: &Path, request: Bisect) -> Result<bisect::Report> {
    let dependency = bisect::dependency(repo, &request.target)?;
    reject_own_override(&request.predicate, &dependency.target)?;
    let target = dependency.target.clone();
    let mut progress = request.progress;
    let mut tested = 0usize;
    bisect::run(
        bisect::Options {
            dependency,
            good: request.good,
            bad: request.bad,
            first_parent: request.first_parent,
            reverse: request.reverse,
            command: request.words,
            run_dir: request.run_dir,
            budget: request.budget,
        },
        |rev, candidate_dir| {
            if let Some(progress) = progress.as_mut() {
                progress(tested)?;
            }
            tested += 1;
            let mut predicate = request.predicate.clone();
            super::request::with_override(&mut predicate, &target, rev);
            crate::support::fs::create_dir_all(candidate_dir)?;
            let run = || {
                super::request::drive(super::request::Drive {
                    repo,
                    source: super::request::Source::Parse {
                        request: predicate,
                        origin: None,
                    },
                    run_dir: candidate_dir.to_path_buf(),
                    cache: super::request::CacheIntent::Off,
                    only: super::request::TaskFilter::All,
                    follow: false,
                    finish: super::request::Finish::Silent,
                })?;
                let report: crate::ci::report::Report =
                    crate::support::schema::read(&crate::ci::prepare::report_path(candidate_dir))?;
                candidate_outcome(&report)
            };
            match &request.event_parent {
                Some(parent) => mirrored_candidate(candidate_dir, parent, &target, rev, run),
                None => run(),
            }
        },
    )
}

fn mirrored_candidate(
    candidate_dir: &Path,
    parent: &Path,
    target: &str,
    rev: &str,
    run: impl FnOnce() -> Result<Outcome>,
) -> Result<Outcome> {
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};

    let short = crate::support::format::short_rev(rev);
    let scope = crate::ci::events::Scope {
        id: format!("bisect-{short}"),
        label: format!("{target} candidate {short}"),
    };
    scope.start(parent)?;
    let stop = Arc::new(AtomicBool::new(false));
    let mirror = {
        let source = candidate_dir.to_path_buf();
        let target = parent.to_path_buf();
        let stop = Arc::clone(&stop);
        std::thread::spawn(move || crate::ci::events::mirror(&source, &target, &stop))
    };
    let outcome = run();
    stop.store(true, Ordering::Relaxed);
    let mirrored = match mirror.join() {
        Ok(mirrored) => mirrored,
        Err(_) => Err(crate::support::error::Error::Failure(
            "candidate event mirror panicked".into(),
        )),
    };
    let outcome =
        crate::support::error::finalize(outcome, mirrored, "could not mirror candidate progress");
    let (status, headline) = match &outcome {
        Ok(Outcome::Good) => (
            crate::support::atoms::TaskStatus::Success,
            "predicate passed",
        ),
        Ok(Outcome::Bad) => (
            crate::support::atoms::TaskStatus::Success,
            "predicate failed",
        ),
        Ok(Outcome::Skip) => (
            crate::support::atoms::TaskStatus::Skipped,
            "predicate skipped",
        ),
        Err(_) => (
            crate::support::atoms::TaskStatus::Failure,
            "candidate errored",
        ),
    };
    let finished = scope.finish(parent, status, headline);
    crate::support::error::finalize(outcome, finished, "could not finish candidate progress")
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
    let predicate = predicate(
        &words,
        &dependency.target,
        args.outcome.blocked,
        super::Surface::Terminal,
    )?;

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

    let report = drive(
        repo,
        Bisect {
            target: args.target,
            good: args.good,
            bad: args.bad,
            first_parent: args.first_parent,
            reverse: args.reverse,
            words,
            predicate,
            run_dir: run_dir.clone(),
            budget: None,
            event_parent: None,
            progress: None,
        },
    )?;

    let what = if report.reverse { "passing" } else { "bad" };
    match &report.first_bad {
        Some(rev) => {
            ui::result(format!("first {what} {} commit: {rev}", report.target));
        }
        None => ui::result(format!("{}: no first-{what} commit found", report.target)),
    }
    ui::fact("report", run_dir.join(bisect::REPORT_FILE).display());
    Ok(CommandStatus::SUCCESS)
}
