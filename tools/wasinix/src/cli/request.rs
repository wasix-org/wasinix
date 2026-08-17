//! From typed arguments to an executed request. Every frontend assembles the
//! same `ParsedRequest`, and every execution passes through [`drive`]: one
//! prepare, one cache policy, one finish.

use std::path::{Path, PathBuf};

use clap::Parser;

use crate::ci::normalize;
use crate::ci::plan::Phase;
use crate::ci::types::{
    Build, Case, Diff, Override, OverrideKind, ParsedRequest, RefSource, Request, ResolvedRequest,
    Selector, SelectorKind, Spot,
};
use crate::support::error::{request_error, Error, Result};
use crate::support::process::CommandStatus;
use crate::support::ui::{self, JsonArg};
use crate::support::schema;

/// The default spot source cut: the toolchain group, since a toolchain edit
/// is what spot exists to test.
const DEFAULT_SPOT_SOURCES: [&str; 1] = ["toolchain"];

/// The selection core both frontends share. Placement and mode flags live in
/// the trusted wrappers only, so a PR comment cannot even spell them.
#[derive(Debug, clap::Args)]
pub struct RequestArgs {
    /// CI sets, named groups, or job addresses to select
    #[arg(required = true, value_name = "SELECTOR")]
    pub selectors: Vec<String>,
    /// Enable jobs requiring this CI tag (repeatable, comma-separated)
    #[arg(long = "enable-tag", value_name = "TAG", value_delimiter = ',')]
    pub enabled_tags: Vec<String>,
    /// Wasinix revision to build; HEAD includes uncommitted changes
    #[arg(long, default_value = "HEAD")]
    pub at: String,
    /// Materialize TARGET from a version or rev:SHA (repeatable)
    #[arg(long = "with", value_name = "TARGET@SOURCE")]
    pub overrides: Vec<String>,
    /// Build a wasinix or dependency pull request; with no value, the
    /// current GitHub pull-request event
    #[arg(
        long,
        value_name = "OWNER/REPO#NUMBER",
        num_args = 0..=1,
        default_missing_value = "current",
        require_equals = true
    )]
    pub from_pr: Option<String>,
}

#[derive(Debug, clap::Args)]
pub struct PlacementArg {
    /// Where to run: local, a remote name, or <remote>:<route>; the
    /// configured default remote when absent
    #[arg(long, value_name = "PLACEMENT")]
    pub on: Option<String>,
}

#[derive(Debug, clap::Args)]
pub struct SpotExtras {
    /// Pristine cached revision below the splice; defaults to --at
    #[arg(long)]
    pub base: Option<String>,
    /// CI job or group selector to take from the changed tree (repeatable)
    #[arg(long, value_name = "SELECTOR")]
    pub from_source: Vec<String>,
    /// Take only the target packages from the changed tree
    #[arg(long, conflicts_with = "from_source")]
    pub target_only: bool,
}

#[derive(Debug, Default, clap::Args)]
pub struct ModeArgs {
    /// Resolve and print the plan without running
    #[arg(long)]
    pub plan: bool,
    #[command(flatten)]
    pub json: JsonArg,
    /// Keep the run's state and artifacts in this directory
    #[arg(long, value_name = "DIR")]
    pub run_dir: Option<PathBuf>,
    /// Write the run's merged junit results to this file
    #[arg(long, value_name = "FILE")]
    pub junit_out: Option<PathBuf>,
    /// Push results and their build-time closure to the cache; requires
    /// NIX_SIGNING_KEY
    #[arg(long)]
    pub push_cache: bool,
    /// Stop after warming evaluation inputs
    #[arg(long)]
    pub inputs_only: bool,
}

#[derive(clap::Args)]
pub struct DiffArgs {
    /// Also compare the built contents of moved outputs
    #[arg(long)]
    pub content_diff: bool,
    #[command(flatten)]
    pub mode: ModeArgs,
    /// The cases, as complete build or spot commands separated by --vs; the
    /// first case is the baseline. None means the pull-request shape:
    /// `build all --at <merge-base with main> --vs build all`
    #[arg(trailing_var_arg = true, allow_hyphen_values = true, value_name = "CASE")]
    pub words: Vec<String>,
}

/// A diff case or a bisect predicate re-enters this parser, so neither verb
/// grows a second grammar for the same commands.
#[derive(Parser)]
#[command(name = "case", no_binary_name = true)]
enum CaseCommand {
    Build(CaseBuild),
    Spot(CaseSpot),
}

#[derive(clap::Args)]
struct CaseBuild {
    #[command(flatten)]
    request: RequestArgs,
    #[command(flatten)]
    placement: PlacementArg,
}

#[derive(clap::Args)]
struct CaseSpot {
    #[command(flatten)]
    request: RequestArgs,
    #[command(flatten)]
    spot: SpotExtras,
    #[command(flatten)]
    placement: PlacementArg,
}

fn parse_override(spec: &str) -> Result<Override> {
    let Some((target, value)) = spec.split_once('@') else {
        return request_error(format!(
            "--with {spec:?}: expected TARGET@VERSION or TARGET@rev:SHA"
        ));
    };
    if target.is_empty() || value.is_empty() {
        return request_error(format!("--with {spec:?}: target and source must be non-empty"));
    }
    let (kind, value) = match crate::support::naming::rev_override(value)? {
        Some(rev) => (OverrideKind::Revision, rev),
        None => (OverrideKind::Release, value),
    };
    Ok(Override {
        target: target.to_string(),
        kind,
        value: value.to_string(),
        repository: None,
        origin: None,
    })
}

fn parse_overrides(specs: &[String]) -> Result<Vec<Override>> {
    specs.iter().map(|spec| parse_override(spec)).collect()
}

/// Which selector kind a word is. Sets and groups are known names; anything
/// else is a job address resolved against the evaluation.
fn selector(word: &str) -> Selector {
    let set = word == "all" || crate::ci::types::SetName::parse(word).is_some();
    Selector {
        kind: if set {
            SelectorKind::Set
        } else {
            SelectorKind::Job
        },
        name: word.to_string(),
    }
}

pub(crate) fn build_case(
    args: &RequestArgs,
    on: Option<String>,
    case_id: Option<String>,
) -> Result<Build<RefSource>> {
    Ok(Build {
        case_id,
        source: RefSource {
            reference: args.at.clone(),
        },
        selectors: args.selectors.iter().map(|word| selector(word)).collect(),
        enabled_tags: args.enabled_tags.clone(),
        overrides: parse_overrides(&args.overrides)?,
        from_pr: args.from_pr.clone(),
        on,
    })
}

pub(crate) fn spot_case(
    args: &RequestArgs,
    extras: &SpotExtras,
    on: Option<String>,
    case_id: Option<String>,
) -> Result<Spot<RefSource>> {
    if !args.enabled_tags.is_empty() {
        return request_error("spot resolves targets by selector; --enable-tag does not apply");
    }
    let from_source = if extras.target_only {
        Vec::new()
    } else if extras.from_source.is_empty() {
        DEFAULT_SPOT_SOURCES.map(str::to_string).to_vec()
    } else {
        extras.from_source.clone()
    };
    Ok(Spot {
        case_id,
        source: RefSource {
            reference: args.at.clone(),
        },
        targets: args.selectors.clone(),
        from_source,
        base: extras.base.clone(),
        overrides: parse_overrides(&args.overrides)?,
        from_pr: args.from_pr.clone(),
        on,
    })
}

/// One trusted build or spot command as a case; the parser diff cases and
/// bisect predicates share.
pub(crate) fn parse_case(words: &[String], case_id: Option<String>) -> Result<Case<RefSource>> {
    let parsed = CaseCommand::try_parse_from(words)
        .map_err(|error| Error::Request(error.to_string()))?;
    Ok(match &parsed {
        CaseCommand::Build(case) => Case::Build(build_case(
            &case.request,
            case.placement.on.clone(),
            case_id,
        )?),
        CaseCommand::Spot(case) => Case::Spot(spot_case(
            &case.request,
            &case.spot,
            case.placement.on.clone(),
            case_id,
        )?),
    })
}

/// Split `--vs`-separated case words and name them base, head, headN.
pub(crate) fn split_cases(words: &[String]) -> Vec<(String, &[String])> {
    words
        .split(|word| word == "--vs")
        .enumerate()
        .map(|(index, case_words)| {
            let case_id = if index == 0 {
                "base".to_string()
            } else if index == 1 {
                "head".to_string()
            } else {
                format!("head{index}")
            };
            (case_id, case_words)
        })
        .collect()
}

/// Assemble a diff from parsed cases; both frontends share the shape, only
/// the case parser differs.
pub(crate) fn diff_of(cases: Vec<Case<RefSource>>, content_diff: bool) -> Result<ParsedRequest> {
    if cases.len() < 2 {
        return request_error("diff needs at least two cases separated by --vs");
    }
    Ok(Request::Diff(Diff {
        baseline: "base".to_string(),
        content_diff,
        cases,
    }))
}

pub(crate) fn diff_request(args: &DiffArgs) -> Result<ParsedRequest> {
    let mut cases: Vec<Case<RefSource>> = Vec::new();
    for (case_id, case_words) in split_cases(&args.words) {
        cases.push(
            parse_case(case_words, Some(case_id.clone()))
                .map_err(|error| Error::Request(format!("diff case {case_id}: {error}")))?,
        );
    }
    diff_of(cases, args.content_diff)
}

/// A run keeps its state and artifacts in one directory. Without one named, a
/// run gets a fresh kept directory and says where it is.
pub(crate) fn run_directory(chosen: &Option<PathBuf>) -> Result<PathBuf> {
    if let Some(path) = chosen {
        return Ok(path.clone());
    }
    let base = crate::support::env::temp_dir().join("wasinix-runs");
    crate::support::fs::create_dir_all(&base)?;
    for nonce in 0u32.. {
        let run_dir = base.join(format!(
            "run-{}-{}-{nonce}",
            std::process::id(),
            crate::support::time::unix_secs()
        ));
        match std::fs::create_dir(&run_dir) {
            Ok(()) => {
                ui::fact("run directory", run_dir.display());
                return Ok(run_dir);
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(crate::support::error::io(&run_dir, error)),
        }
    }
    unreachable!("the nonce loop returns or errors")
}

/// The request header: what each case is, where it runs.
fn case_facts(resolved: &ResolvedRequest) {
    for case in resolved.cases() {
        let mut parts = vec![match case {
            crate::ci::types::CaseRef::Build(build) => format!(
                "build {} at {}",
                build
                    .selectors
                    .iter()
                    .map(|selector| selector.name.as_str())
                    .collect::<Vec<_>>()
                    .join(" "),
                build.source.rev
            ),
            crate::ci::types::CaseRef::Spot(spot) => {
                format!("spot {} at {}", spot.targets.join(" "), spot.source.rev)
            }
        }];
        if let crate::ci::types::CaseRef::Build(build) = case {
            if build.source.working_tree {
                parts.push("working tree".to_string());
            }
        }
        parts.push(format!(
            "on {}",
            case.placement().unwrap_or("default remote")
        ));
        ui::fact(case.case_id(), ui::counts(&parts));
    }
}

#[derive(serde::Serialize, serde::Deserialize)]
struct Resolution {
    request: ResolvedRequest,
    plan: crate::ci::plan::Plan,
}
impl schema::Document for Resolution {
    const KIND: &'static str = "resolution";
    const SCHEMA: u32 = 1;
}

/// The `--plan` verb: resolve, print the plan, and for spot also resolve the
/// splice so the base/change counts surface before anything builds.
fn plan(repo: &Path, resolved: &ResolvedRequest, mode: &ModeArgs) -> Result<CommandStatus> {
    let plan = crate::ci::plan::plan_of(resolved, None, &[]);
    ui::emit(
        &mode.json,
        &Resolution {
            request: resolved.clone(),
            plan,
        },
        |resolution| {
            case_facts(&resolution.request);
            for task in &resolution.plan.tasks {
                ui::fact("task", &task.task_id);
            }
        },
    )?;
    if matches!(resolved, Request::Spot(_)) && !mode.json.wants() {
        let run_dir = run_directory(&mode.run_dir)?;
        // The probe reproduces the prepared case, whose source carries the
        // recorded materialization-patch hash; the pre-prepare request does
        // not, and a dirty tree would trip the reproduction guard.
        let loaded = crate::ci::prepare::prepare_all(repo, resolved, &run_dir)?;
        if let Request::Spot(spot) = &loaded.request {
            crate::ci::exec::spot_probe(
                &crate::ci::exec::Context {
                    runner_root: repo,
                    run_dir: &run_dir,
                    push_cache: false,
                },
                spot,
            )?;
        }
    }
    Ok(CommandStatus::SUCCESS)
}

/// Print the finished run's answer: the report title, or under --json the
/// whole report document on stdout. A run that ended without a report (a
/// cancel, a dead supervisor) already had its state reported, so a missing
/// report is a note, not an error.
pub(crate) fn report_result(run_dir: &Path) -> Result<()> {
    let path = crate::ci::prepare::report_path(run_dir);
    if !path.exists() {
        ui::note("the run ended without a report");
        return Ok(());
    }
    let report: crate::ci::report::Report = schema::read(&path)?;
    ui::result(&report.title);
    Ok(())
}

fn export_junit(run_dir: &Path, out: &Path) -> Result<()> {
    let mut merged: Vec<crate::ci::facts::junit::Case> = Vec::new();
    let cases_dir = crate::ci::prepare::cases_dir(run_dir);
    let mut case_dirs: Vec<PathBuf> = std::fs::read_dir(&cases_dir)
        .map_err(|e| crate::support::error::io(&cases_dir, e))?
        .flatten()
        .map(|entry| entry.path())
        .collect();
    case_dirs.sort();
    for case_dir in case_dirs {
        let case_id = case_dir
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default();
        let junit = crate::ci::prepare::junit_dir(&case_dir);
        let mut junits: Vec<PathBuf> = std::fs::read_dir(&junit)
            .map(|files| {
                files
                    .flatten()
                    .map(|file| file.path())
                    .filter(|path| path.extension().is_some_and(|ext| ext == "xml"))
                    .collect()
            })
            .unwrap_or_default();
        junits.sort();
        // Prefix each case's jobs with its case id: a diff's two cases cover
        // the same jobs, and merging them unprefixed would double every name
        // and export the baseline's pre-existing failures as this run's.
        for mut case in crate::ci::facts::junit::parse_junits(&junits, false).unwrap_or_default() {
            case.attr = format!("{case_id}::{}", case.attr);
            merged.push(case);
        }
    }
    crate::support::fs::write(out, crate::ci::facts::junit::write_junit(&merged).as_bytes())
}

/// Whether this request's placement is a host route, which ships the whole
/// run to the remote instead of executing here.
fn host_builder(
    repo: &Path,
    resolved: &ResolvedRequest,
) -> Result<Option<crate::nix::builder::Builder>> {
    let mut placements: Vec<Option<&str>> =
        resolved.cases().iter().map(|case| case.placement()).collect();
    placements.dedup();
    let mut host = None;
    for on in &placements {
        if let crate::nix::route::Route::Host(builder) =
            crate::nix::route::Route::from_on(repo, *on)?
        {
            host = Some(builder);
        }
    }
    if host.is_some() && placements.len() > 1 {
        return request_error(
            "a host-routed case cannot mix with other placements in one run",
        );
    }
    Ok(host)
}

/// Ship a resolved request to a host and observe it to completion. The
/// operator's cache intent and trust refs travel with it, so a host-routed
/// run pushes to the cache under exactly the local rules.
pub(crate) fn run_on_host(
    repo: &Path,
    builder: &crate::nix::builder::Builder,
    mut request: ResolvedRequest,
    run_dir: &Path,
    cache: CacheIntent,
) -> Result<CommandStatus> {
    // The host builds on itself; the placement axis was consumed by
    // choosing it.
    request.set_placement(Some("local".to_string()));
    let scratch = crate::support::fs::Scratch::create("wasinix-remote")?;
    let shipped = scratch.path().join("request.json");
    schema::write(&shipped, &request)?;
    let mut payload_tail = Vec::new();
    if matches!(cache, CacheIntent::Push) {
        payload_tail.push("--push-cache".to_string());
    }
    let mut renderer = crate::cli::render::LineRenderer::new();
    let status = crate::runs::remote::run(crate::runs::remote::Request {
        repo,
        builder,
        inputs: vec![(shipped, "request.json".to_string())],
        payload: &|state| {
            let mut words = vec![
                "ci".to_string(),
                "run".to_string(),
                "--request".to_string(),
                format!("{state}/request.json"),
            ];
            words.extend(payload_tail.clone());
            words
        },
        fetch_to: run_dir,
        progress: &mut |event| renderer.event(event),
    });
    renderer.finish();
    status
}

/// Whether this run intends to push to the shared cache.
#[derive(Clone, Copy)]
pub(crate) enum CacheIntent {
    Off,
    Push,
}

/// The one cache decision: operator intent and the signing key, in every
/// frontend. Trust gates the rev-keyed baseline publish, not this.
pub(crate) fn cache_policy(intent: CacheIntent) -> Result<bool> {
    match intent {
        CacheIntent::Off => Ok(false),
        CacheIntent::Push => {
            if crate::support::env::signing_key()?.is_none() {
                return request_error("--push-cache requires NIX_SIGNING_KEY");
            }
            // Store paths are input-addressed, so a consumer only ever
            // requests paths its own eval derived: pushing an experiment's
            // artifacts adds reuse, never confusion. Trust gates the
            // rev-keyed baseline documents instead.
            Ok(true)
        }
    }
}

/// Where a drive's request comes from.
pub(crate) enum Source<'a> {
    /// A frontend's parsed request, normalized here.
    Parse {
        request: ParsedRequest,
        origin: Option<&'a crate::ci::origin::Origin>,
    },
    /// An already-resolved request (a shipped document, or the terminal's
    /// own normalization after host routing was decided).
    Resolved(ResolvedRequest),
    /// A run directory `ci prepare` already materialized.
    Prepared,
}

/// Which planned tasks run. Only [`TaskFilter::All`] folds a report and
/// finishes; a partial run leaves the directory for the caller.
pub(crate) enum TaskFilter {
    All,
    InputsOnly,
    Tasks(Vec<String>),
}

/// What the caller wants printed when a full run finishes.
pub(crate) enum Finish {
    /// The interactive answer: junit export, then the report title or the
    /// --json document.
    Interactive {
        junit_out: Option<PathBuf>,
        json: JsonArg,
    },
    /// The payload answer: the report title, for the durable log.
    Headline,
    /// Nothing; the caller reads the run directory itself.
    Silent,
}

pub(crate) struct Drive<'a> {
    pub repo: &'a Path,
    pub source: Source<'a>,
    pub run_dir: PathBuf,
    pub cache: CacheIntent,
    pub only: TaskFilter,
    /// Render live progress on the terminal while the run executes.
    pub follow: bool,
    pub finish: Finish,
}

/// The one execution path: prepare (or load), decide the cache, run the
/// plan, finish. Host routing is the terminal entry's decision before this;
/// a driven run never re-ships.
pub(crate) fn drive(drive: Drive<'_>) -> Result<CommandStatus> {
    let loaded = match &drive.source {
        Source::Parse { request, origin } => {
            let context = normalize::Context {
                repo: drive.repo,
                origin: *origin,
            };
            let resolved = normalize::normalize(request, &context)?;
            case_facts(&resolved);
            crate::ci::prepare::prepare_all(drive.repo, &resolved, &drive.run_dir)?
        }
        Source::Resolved(resolved) => {
            case_facts(resolved);
            crate::ci::prepare::prepare_all(drive.repo, resolved, &drive.run_dir)?
        }
        Source::Prepared => crate::ci::prepare::load(&drive.run_dir)?,
    };
    let push_cache = cache_policy(drive.cache)?;
    let only: Vec<String> = match &drive.only {
        TaskFilter::All => Vec::new(),
        TaskFilter::InputsOnly => loaded
            .plan()
            .tasks
            .iter()
            .filter(|task| matches!(task.phase, Phase::EvalInputs))
            .map(|task| task.task_id.clone())
            .collect(),
        TaskFilter::Tasks(tasks) => tasks.clone(),
    };

    let context = crate::ci::exec::Context {
        runner_root: drive.repo,
        run_dir: &drive.run_dir,
        push_cache,
    };
    let status = if drive.follow {
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let follower = {
            let run_dir = drive.run_dir.clone();
            let stop = std::sync::Arc::clone(&stop);
            std::thread::spawn(move || super::render::follow(&run_dir, &stop))
        };
        let status = crate::ci::exec::run_tasks(&context, &loaded, &only);
        stop.store(true, std::sync::atomic::Ordering::Relaxed);
        if let Ok(Err(error)) = follower.join() {
            ui::warning(format!("progress rendering stopped: {error}"));
        }
        status?
    } else {
        crate::ci::exec::run_tasks(&context, &loaded, &only)?
    };

    if matches!(drive.only, TaskFilter::All) {
        match &drive.finish {
            Finish::Interactive { junit_out, json } => {
                if let Some(out) = junit_out {
                    export_junit(&drive.run_dir, out)?;
                }
                if json.wants() {
                    let report: serde_json::Value = crate::support::json::read(
                        &crate::ci::prepare::report_path(&drive.run_dir),
                    )?;
                    ui::emit_value(json, &report, || {})?;
                } else {
                    report_result(&drive.run_dir)?;
                }
            }
            Finish::Headline => report_result(&drive.run_dir)?,
            Finish::Silent => {}
        }
    }
    Ok(status)
}

/// The terminal entry point: plan or run, with host routing decided here and
/// nowhere else.
fn drive_terminal(repo: &Path, request: ParsedRequest, mode: &ModeArgs) -> Result<CommandStatus> {
    let cache = if mode.push_cache {
        CacheIntent::Push
    } else {
        CacheIntent::Off
    };
    let context = normalize::Context { repo, origin: None };
    let resolved = normalize::normalize(&request, &context)?;
    if mode.plan {
        return plan(repo, &resolved, mode);
    }
    if let Some(builder) = host_builder(repo, &resolved)? {
        case_facts(&resolved);
        let run_dir = run_directory(&mode.run_dir)?;
        let status = run_on_host(
            repo,
            &builder,
            resolved,
            &run_dir,
            cache,
        )?;
        if let Some(out) = &mode.junit_out {
            export_junit(&run_dir, out)?;
        }
        report_result(&run_dir)?;
        return Ok(status);
    }
    drive(Drive {
        repo,
        source: Source::Resolved(resolved),
        run_dir: run_directory(&mode.run_dir)?,
        cache,
        only: if mode.inputs_only {
            TaskFilter::InputsOnly
        } else {
            TaskFilter::All
        },
        follow: true,
        finish: Finish::Interactive {
            junit_out: mode.junit_out.clone(),
            json: mode.json,
        },
    })
}

/// Add an override to a parsed request's every case. Bisect owns the
/// dependency override; the predicate command may not also carry it.
pub(crate) fn with_override(request: &mut ParsedRequest, target: &str, rev: &str) {
    let over = Override {
        target: target.to_string(),
        kind: OverrideKind::Revision,
        value: rev.to_string(),
        repository: None,
        origin: None,
    };
    let cases: Vec<&mut Vec<Override>> = match request {
        Request::Build(build) => vec![&mut build.overrides],
        Request::Spot(spot) => vec![&mut spot.overrides],
        Request::Diff(diff) => diff
            .cases
            .iter_mut()
            .map(|case| match case {
                Case::Build(build) => &mut build.overrides,
                Case::Spot(spot) => &mut spot.overrides,
            })
            .collect(),
    };
    for overrides in cases {
        overrides.push(over.clone());
    }
}

pub(crate) fn run_build(repo: &Path, args: super::BuildArgs) -> Result<CommandStatus> {
    let request = Request::Build(build_case(&args.request, args.placement.on.clone(), None)?);
    drive_terminal(repo, request, &args.mode)
}

pub(crate) fn run_spot(repo: &Path, args: super::SpotArgs) -> Result<CommandStatus> {
    if args.mode.inputs_only {
        return request_error("--inputs-only applies to build, not spot");
    }
    let request = Request::Spot(spot_case(
        &args.request,
        &args.spot,
        args.placement.on.clone(),
        None,
    )?);
    drive_terminal(repo, request, &args.mode)
}

/// The base a bare `diff` compares against: the merge base of HEAD and the
/// first main ref that exists, mirroring what CI computes for a pull
/// request.
pub(crate) fn pr_base(repo: &Path) -> Result<String> {
    for reference in ["upstream/main", "origin/main", "main"] {
        if crate::support::git::resolve_rev(repo, reference).is_ok() {
            return crate::support::git::git(repo, &["merge-base", reference, "HEAD"]);
        }
    }
    request_error("no main ref to diff against (tried upstream/main, origin/main, main); name the cases explicitly")
}

pub(crate) fn run_diff(repo: &Path, mut args: super::DiffArgs) -> Result<CommandStatus> {
    if args.words.is_empty() {
        let base = pr_base(repo)?;
        ui::fact(
            "diff",
            format!(
                "build all --at {} --vs build all",
                crate::support::format::short_rev(&base)
            ),
        );
        args.words = ["build", "all", "--at", &base, "--vs", "build", "all"]
            .into_iter()
            .map(str::to_string)
            .collect();
    }
    if args.mode.inputs_only {
        return request_error("--inputs-only applies to build, not diff");
    }
    let request = diff_request(&args)?;
    drive_terminal(repo, request, &args.mode)
}
