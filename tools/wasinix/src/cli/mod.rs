//! The command tree. Verbs act on the tree, nouns have lifecycles, and every
//! frontend (terminal, PR comments) enters through the same parsers.

pub(crate) mod bisect;
pub(crate) mod preview;
pub(crate) mod registries;
pub(crate) mod remote;
pub(crate) mod render;
pub(crate) mod request;
pub(crate) mod surface;
pub(crate) mod timings;
pub mod untrusted;
pub(crate) mod update;

use std::path::PathBuf;

use clap::Parser;

use crate::runs;
use crate::support::error::Result;
use crate::support::process::CommandStatus;
use crate::support::{schema, ui};

pub use request::{DiffArgs, ModeArgs, OutcomeArgs, RequestArgs, SpotExtras};
pub(crate) use surface::Surface;

#[derive(Parser)]
#[command(
    name = "wasinix",
    version,
    about = "Tooling for the wasinix package repository.",
    subcommand_required = true,
    arg_required_else_help = true,
    disable_help_subcommand = true
)]
pub struct Cli {
    /// Show raw child output and echoes
    #[arg(short, long, global = true, conflicts_with = "quiet")]
    pub verbose: bool,
    /// Show only failures and the verdict
    #[arg(short, long, global = true)]
    pub quiet: bool,
    #[arg(long, global = true, value_enum, default_value_t = ColorMode::Auto)]
    pub color: ColorMode,
    #[command(subcommand)]
    pub command: CommandTree,
}

#[derive(Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
pub enum ColorMode {
    Auto,
    Always,
    Never,
}

#[derive(clap::Subcommand)]
pub enum CommandTree {
    /// Build the selected CI sets, groups, or jobs
    Build(BuildArgs),
    /// Rebuild attrs from a changed tree over a cached base revision
    Spot(SpotArgs),
    /// Compare complete build or spot cases against a baseline
    #[command(
        after_help = "Each case is a complete build or spot command; the first is the baseline:\n  wasinix diff build all --at main --vs build all"
    )]
    Diff(DiffArgs),
    /// Find the dependency commit that first breaks a predicate
    Bisect(bisect::BisectArgs),
    /// Search the job addresses known from the last recorded evaluation
    Jobs {
        /// Dotted segments matched against any window of an address: a bare
        /// segment by substring, a starred one as a glob (`*` never crosses
        /// a dot), so `hydra` and `wheel*hydra*` both find their jobs
        #[arg(add = clap_complete::ArgValueCandidates::new(request::selector_candidates))]
        pattern: Option<String>,
        #[command(flatten)]
        json: ui::JsonArg,
    },
    /// First-run facts: what is configured, what is missing, and the fix
    Doctor,
    /// What CI spent its time on across a commit range, from the timings
    /// each build publishes
    Timings(timings::TimingsArgs),
    /// The shared binary cache
    #[command(subcommand)]
    Cache(CacheCommand),
    /// Start and inspect durable runs
    #[command(subcommand)]
    Run(RunCommand),
    /// The overlay cargo registry
    #[command(subcommand)]
    Cargo(registries::CargoCommand),
    /// The wasmer webc registry
    #[command(subcommand)]
    Wasmer(registries::WasmerCommand),
    /// The python wheel registry
    #[command(subcommand)]
    Python(registries::PythonCommand),
    /// Publish to every registry
    Publish {
        #[arg(long)]
        dry_run: bool,
    },
    /// Publish a pull request's changed packages as an ephemeral preview
    Preview(preview::PreviewArgs),
    /// Serve all three registries locally at once
    Serve {
        /// A built mint for the cargo leg; built fresh when absent
        #[arg(long)]
        mint: Option<PathBuf>,
        /// A built index for the python leg; built fresh when absent
        #[arg(long)]
        index: Option<PathBuf>,
        /// A built cargo server package; built fresh when absent
        #[arg(long)]
        server: Option<PathBuf>,
        /// Prebuilt webc trees for the wasmer leg; all shipped when absent
        #[arg(long = "webc")]
        webcs: Vec<PathBuf>,
        /// Run a command against all three and exit with its status
        #[arg(last = true)]
        exec: Vec<String>,
    },
    /// Update the repo's pins
    Update(update::UpdateArgs),
    /// Maintain the registry-history and publication-release tables
    #[command(subcommand)]
    Versions(update::VersionsCommand),
    /// Inspect and verify the configured remote builders
    #[command(subcommand)]
    Remote(remote::RemoteCommand),
    /// Internal CI plumbing invoked by adapters and durable runs
    #[command(subcommand, hide = true)]
    Ci(CiCommand),
    /// Generate shell completions
    Completions {
        #[arg(value_enum)]
        shell: clap_complete::Shell,
    },
    /// Discard a managed pull-request branch and replay its recipe
    #[command(hide = true)]
    Regenerate,
    /// Format a pull-request branch and commit the result
    #[command(hide = true)]
    Fmt,
    /// Show help for the active command surface
    #[command(name = "help", hide = true)]
    SurfaceHelp,
}

#[derive(clap::Args)]
pub struct BuildArgs {
    #[command(flatten)]
    pub request: RequestArgs,
    #[command(flatten)]
    pub placement: request::PlacementArg,
    #[command(flatten)]
    pub mode: ModeArgs,
    #[command(flatten)]
    pub outcome: OutcomeArgs,
}

#[derive(clap::Args)]
pub struct SpotArgs {
    #[command(flatten)]
    pub request: RequestArgs,
    #[command(flatten)]
    pub spot: SpotExtras,
    #[command(flatten)]
    pub placement: request::PlacementArg,
    #[command(flatten)]
    pub mode: ModeArgs,
    #[command(flatten)]
    pub outcome: OutcomeArgs,
}

#[derive(clap::Subcommand)]
pub enum CacheCommand {
    /// Push outputs already built for this working tree that the cache lacks
    Push {
        /// Job selectors, as in `build`; everything evaluated when empty
        #[arg(add = clap_complete::ArgValueCandidates::new(request::selector_candidates))]
        selectors: Vec<String>,
        #[command(flatten)]
        json: ui::JsonArg,
    },
}

#[derive(clap::Subcommand)]
pub enum RunCommand {
    /// Start a durable command and print its run id
    Start {
        /// Wait for the run to finish instead of returning the id immediately
        #[arg(long, conflicts_with = "follow")]
        wait: bool,
        /// Narrate the run like `run watch`; interrupting the watcher
        /// detaches, the run keeps going
        #[arg(long)]
        follow: bool,
        /// The command to run, executed verbatim, so a wasinix payload names
        /// the binary: `run start -- wasinix build all`. The payload receives
        /// --run-dir automatically.
        #[arg(trailing_var_arg = true, required = true)]
        command: Vec<String>,
    },
    /// List durable runs, newest first
    List {
        /// Only runs still starting or running
        #[arg(long)]
        active: bool,
        #[command(flatten)]
        json: ui::JsonArg,
    },
    /// Show a run's state and progress snapshot
    Status {
        #[arg(add = clap_complete::ArgValueCandidates::new(run_id_candidates))]
        run_id: String,
        #[command(flatten)]
        json: ui::JsonArg,
    },
    /// Print a run's log tail, optionally following until it finishes
    Logs {
        #[arg(add = clap_complete::ArgValueCandidates::new(run_id_candidates))]
        run_id: String,
        #[arg(long)]
        follow: bool,
    },
    /// Print the run's folded report
    Report {
        #[arg(add = clap_complete::ArgValueCandidates::new(run_id_candidates))]
        run_id: String,
        #[command(flatten)]
        json: ui::JsonArg,
    },
    /// List the run's build failures with their causes
    Failures {
        #[arg(add = clap_complete::ArgValueCandidates::new(run_id_candidates))]
        run_id: String,
        #[command(flatten)]
        json: ui::JsonArg,
    },
    /// Narrate the run's event stream until it finishes
    Watch {
        #[arg(add = clap_complete::ArgValueCandidates::new(run_id_candidates))]
        run_id: String,
    },
    /// Wait until a run reaches a final state
    Wait {
        #[arg(add = clap_complete::ArgValueCandidates::new(run_id_candidates))]
        run_id: String,
        /// Give up observing after this many seconds; the run itself keeps going
        #[arg(long)]
        timeout: Option<u64>,
    },
    /// Ask a run's supervisor to terminate the payload's process group
    Cancel {
        /// A local run id, or `<remote>:<run>` for a run hosted on a builder
        #[arg(add = clap_complete::ArgValueCandidates::new(run_id_candidates))]
        run_id: String,
    },
    #[command(hide = true)]
    Supervise {
        run_dir: PathBuf,
        #[arg(trailing_var_arg = true, required = true)]
        command: Vec<String>,
    },
}

#[derive(clap::Subcommand)]
pub enum CiCommand {
    /// Print the nix config block workflows install, from the constants the
    /// binary trusts, so the cache identity has one home
    NixConfig,
    /// Prepare and execute a resolved request in one payload, which is the
    /// command durable runs supervise
    Run {
        #[arg(long)]
        request: PathBuf,
        #[arg(long)]
        run_dir: PathBuf,
        /// Push trusted results to the shared cache; requires NIX_SIGNING_KEY
        #[arg(long)]
        push_cache: bool,
    },
    /// Run a resolved request durably on a remote host and fetch the run back
    Remote {
        #[arg(long)]
        request: PathBuf,
        /// Local directory the finished run is copied into
        #[arg(long)]
        run_dir: PathBuf,
        /// The remote to run on; the configured default when absent
        #[arg(long)]
        on: Option<String>,
    },
    /// Attach to a remote run and fetch it once it is final
    Observe {
        /// The run directory on the remote host
        #[arg(long)]
        remote_run_dir: String,
        /// Local directory the run is mirrored and fetched into
        #[arg(long)]
        run_dir: PathBuf,
        #[arg(long)]
        on: Option<String>,
    },
    /// Materialize a resolved request into a run directory
    Prepare {
        /// The resolved request document to prepare
        #[arg(long)]
        request: PathBuf,
        #[arg(long)]
        run_dir: PathBuf,
    },
    /// Execute a prepared run's plan
    Exec {
        #[arg(long)]
        run_dir: PathBuf,
        /// Run only the named tasks instead of the whole plan
        #[arg(long = "task")]
        tasks: Vec<String>,
        /// Push trusted results to the shared cache; requires NIX_SIGNING_KEY
        #[arg(long)]
        push_cache: bool,
    },
    /// Publish a run's report to its GitHub surfaces
    Publish {
        #[arg(long)]
        run_dir: PathBuf,
        #[command(flatten)]
        surface: crate::github::surfaces::SurfaceArgs,
        #[arg(long)]
        sha: Option<String>,
        /// Render every surface but write none of them
        #[arg(long)]
        dry_run: bool,
        /// Upsert the PR comment
        #[arg(long)]
        comment: bool,
        /// Create or complete the check run
        #[arg(long)]
        check: bool,
        /// Append the full projection to this file ($GITHUB_STEP_SUMMARY)
        #[arg(long)]
        step_summary: Option<PathBuf>,
        /// Publish every built case's eval map for future reuse
        #[arg(long)]
        baseline: bool,
        /// Publish the comment as a reply keyed to this command comment
        /// instead of the sticky report
        #[arg(long)]
        reply_to: Option<u64>,
        /// The report came from a fork PR's own code: conclude neutral and
        /// mark every surface advisory
        #[arg(long)]
        untrusted: bool,
        /// Keep republishing while the run executes and return once it is
        /// final; the finished run still needs a plain publish
        #[arg(long, conflicts_with_all = ["baseline", "step_summary"])]
        watch: bool,
        /// Upload each failure's build log to the cache bucket and link the
        /// comment's rows to them; needs the store that built and S3
        /// credentials
        #[arg(long, conflicts_with = "watch")]
        failure_logs: bool,
        /// Seconds between watch updates
        #[arg(long, default_value_t = 300, requires = "watch")]
        interval: u64,
    },
    /// Authorize a `/wasinix` pull-request comment and describe its run
    Origin {
        /// The issue_comment event payload
        #[arg(long)]
        event: PathBuf,
        /// Owner the origin repository must belong to
        #[arg(long)]
        allowed_owner: Option<String>,
        /// Where step outputs (kind, commentId, ...) are appended
        #[arg(long)]
        github_output: Option<PathBuf>,
        /// Where the authorized command document is written
        #[arg(long)]
        out: PathBuf,
    },
    /// Execute an authorized comment command against its verified origin
    Command {
        /// The authorized command document `ci origin` wrote
        #[arg(long)]
        origin: PathBuf,
        #[arg(long)]
        run_dir: PathBuf,
        /// Push trusted results to the shared cache; requires NIX_SIGNING_KEY
        #[arg(long)]
        push_cache: bool,
    },
    /// Authorize a comment mutation and run it against the PR worktree,
    /// leaving a bundle for the publish job; carries no push credential
    Mutate {
        /// The authorized command document `ci origin` wrote
        #[arg(long)]
        origin: PathBuf,
        /// Where the bundle, context, and changeset land
        #[arg(long)]
        out_dir: PathBuf,
    },
    /// Verify and push a mutation's bundle, reply, and record the state;
    /// the only mutation job with a write token
    MutatePublish {
        #[arg(long)]
        out_dir: PathBuf,
    },
    /// Record a workflow run's step durations: a step-summary table, and
    /// with --publish a document the timings fold reads back
    StepTimings {
        /// The run to read; the current one by default (GITHUB_RUN_ID)
        #[arg(long)]
        run_id: Option<u64>,
        /// The revision the run built, which the document is keyed by
        #[arg(long)]
        rev: Option<String>,
        #[arg(long)]
        repository: Option<String>,
        /// Append the table here ($GITHUB_STEP_SUMMARY)
        #[arg(long)]
        step_summary: Option<PathBuf>,
        /// Upload the document to the cache; needs the S3 credentials
        #[arg(long)]
        publish: bool,
        #[arg(long)]
        dry_run: bool,
    },
    /// Reply to a `/wasinix` command whose run died before it could publish
    /// a report
    Reply {
        #[command(flatten)]
        surface: crate::github::surfaces::SurfaceArgs,
        /// The command comment the reply is keyed to
        #[arg(long)]
        comment_id: u64,
        /// Files whose tail describes the failure; missing ones are skipped
        #[arg(long = "failure")]
        failures: Vec<PathBuf>,
    },
}

/// A pattern segment containing a glob character matches like a build
/// selector; a bare one matches by substring, and the segments slide over
/// the address, so `hydra` finds `pythonWheels.py313.hydra-core` without
/// knowing the address shape.
pub(crate) fn job_pattern_matches(pattern: &str, name: &str) -> bool {
    let wanted: Vec<&str> = pattern.split('.').collect();
    let parts: Vec<&str> = name.split('.').collect();
    if wanted.len() > parts.len() {
        return false;
    }
    parts.windows(wanted.len()).any(|window| {
        window.iter().zip(&wanted).all(|(part, wanted)| {
            if wanted.contains(['*', '?', '[']) {
                crate::support::naming::matches_glob(wanted, part)
            } else {
                part.contains(wanted)
            }
        })
    })
}

fn jobs_command(pattern: Option<String>, json: ui::JsonArg) -> Result<CommandStatus> {
    #[derive(serde::Serialize, serde::Deserialize)]
    struct JobCatalog {
        names: Vec<String>,
    }
    impl schema::Document for JobCatalog {
        const KIND: &'static str = "jobCatalog";
        const SCHEMA: u32 = 1;
    }
    let all = crate::support::completions::recall("selectors");
    if all.is_empty() {
        return Err(crate::support::error::Error::Request(
            "no evaluation has recorded the job catalog yet; any build, spot, or diff \
             records it as its evaluation finishes"
                .into(),
        ));
    }
    if let Some(age) = crate::support::completions::age("selectors") {
        ui::fact(
            "catalog",
            format!(
                "{} names, recorded {} ago",
                all.len(),
                crate::support::format::duration(age.as_secs_f64())
            ),
        );
    }
    let names: Vec<String> = match &pattern {
        Some(pattern) => all
            .into_iter()
            .filter(|name| job_pattern_matches(pattern, name))
            .collect(),
        None => all,
    };
    if names.is_empty() {
        ui::note("no matches");
    }
    ui::emit(&json, &JobCatalog { names }, |catalog| {
        for name in &catalog.names {
            ui::result(name);
        }
    })?;
    Ok(CommandStatus::SUCCESS)
}

/// The newest local run whose materialized tree matches, and its eval map:
/// a build of this exact content already answered what the jobs are.
fn recorded_eval(tree: &str) -> Result<Option<(String, crate::ci::evalmap::EvalMap)>> {
    for run in runs::list()? {
        let run_dir = runs::dir_of(&run.run_id)?;
        let Ok(entries) = std::fs::read_dir(crate::ci::prepare::cases_dir(&run_dir)) else {
            continue;
        };
        for entry in entries.flatten() {
            let case = entry.path();
            let manifest: crate::ci::workspace::Materialization =
                match schema::read(&case.join("prepared/materialization.json")) {
                    Ok(manifest) => manifest,
                    Err(_) => continue,
                };
            if manifest.tree != tree {
                continue;
            }
            if let Ok(map) = schema::read::<crate::ci::evalmap::EvalMap>(
                &crate::ci::prepare::eval_map_path(&case),
            ) {
                return Ok(Some((run.run_id, map)));
            }
        }
    }
    Ok(None)
}

/// One table of first-run facts, each red row naming its fix. Reporting is
/// the whole job: a half-configured machine is a state, not an error.
fn doctor() -> Result<CommandStatus> {
    let mut rows: Vec<Vec<String>> = Vec::new();
    let mut row = |check: &str, ok: bool, detail: String| {
        rows.push(vec![
            check.to_string(),
            if ok { "ok" } else { "--" }.to_string(),
            detail,
        ]);
    };

    let config = crate::nix::builder::config_path()?;
    let configured = config.exists();
    row(
        "builders.toml",
        configured,
        if configured {
            config.display().to_string()
        } else {
            "missing; `wasinix remote init` writes a template".to_string()
        },
    );

    if configured {
        match crate::support::git::repo_root()
            .and_then(|repo| crate::nix::builder::load(&repo, None))
        {
            Ok(builder) => {
                let reachable = builder.reachable().is_ok();
                row(
                    "default remote",
                    reachable,
                    if reachable {
                        format!("{} ({})", builder.name, builder.host)
                    } else {
                        format!("{} unreachable; `wasinix remote doctor`", builder.name)
                    },
                );
            }
            Err(error) => row("default remote", false, error.to_string()),
        }
    } else {
        row(
            "default remote",
            false,
            "none until builders.toml exists".to_string(),
        );
    }

    let key = crate::support::env::signing_key()?.is_some();
    row(
        "signing key",
        key,
        if key {
            "NIX_SIGNING_KEY set; --push-cache and `cache push` work".to_string()
        } else {
            "NIX_SIGNING_KEY unset; builds work, pushing to the cache does not".to_string()
        },
    );
    let aws = crate::support::env::push_credentials()?
        .iter()
        .any(|(name, _)| name == "AWS_ACCESS_KEY_ID");
    row(
        "S3 credentials",
        aws,
        if aws {
            "AWS credentials set".to_string()
        } else {
            "AWS_ACCESS_KEY_ID unset; cache pushes cannot upload".to_string()
        },
    );

    let catalog = crate::support::completions::recall("selectors");
    row(
        "job catalog",
        !catalog.is_empty(),
        if catalog.is_empty() {
            "empty; the first build, spot, or diff records it".to_string()
        } else {
            let age = crate::support::completions::age("selectors")
                .map(|age| {
                    format!(
                        ", recorded {} ago",
                        crate::support::format::duration(age.as_secs_f64())
                    )
                })
                .unwrap_or_default();
            format!("{} names{age}", catalog.len())
        },
    );

    ui::output(crate::support::table::render(
        Some(&["check", "state", "detail"]),
        &rows,
    ));
    Ok(CommandStatus::SUCCESS)
}

fn cache_command(command: CacheCommand) -> Result<CommandStatus> {
    let CacheCommand::Push { selectors, json } = command;
    #[derive(serde::Serialize, serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct CachePush {
        candidates: usize,
        in_cache: usize,
        unbuilt: usize,
        paths: usize,
    }
    impl schema::Document for CachePush {
        const KIND: &'static str = "cachePush";
        const SCHEMA: u32 = 1;
    }

    // Checked before the worktree and a possible evaluation are paid for.
    if crate::support::env::signing_key()?.is_none() {
        return crate::support::error::request_error("pushing to the cache needs NIX_SIGNING_KEY");
    }
    let repo = crate::support::git::repo_root()?;
    let (worktree, rev, tree) = crate::ci::workspace::working_worktree(&repo)?;
    let route = crate::nix::route::Route::from_on(&repo, Some("local"))?;
    let map = match recorded_eval(&tree)? {
        Some((run_id, map)) => {
            ui::fact("evaluation", format!("recorded by run {run_id}"));
            map
        }
        None => {
            ui::fact(
                "evaluation",
                "none recorded for this tree; evaluating locally",
            );
            let scratch = crate::support::env::temp_dir()
                .join(format!("wasinix-cache-push-{}", std::process::id()));
            crate::support::fs::create_dir_all(&scratch)?;
            let jobs_path = scratch.join("jobs.jsonl");
            let attr = format!(
                ".#legacyPackages.{}.ciSets.all",
                crate::support::nix::SYSTEM
            );
            if let Some(error) = crate::nix::evaljobs::run(&crate::nix::evaljobs::RunRequest {
                workdir: worktree.path(),
                flake: &attr,
                jobs_path: &jobs_path,
                stderr_log: &scratch.join("evaluate.log"),
                offline: false,
                check_cache: false,
                route: &route,
            })? {
                return Err(crate::support::error::Error::Failure(format!(
                    "evaluation failed: {error}"
                )));
            }
            let jobs =
                crate::nix::evaljobs::parse_file(&crate::support::fs::read_to_string(&jobs_path)?)?;
            crate::ci::evalmap::EvalMap::from_jobs(rev, &jobs)
        }
    };
    drop(worktree);

    let jobs: Vec<String> = if selectors.is_empty() {
        map.jobs
            .keys()
            .map(|job| job.as_str().to_string())
            .collect()
    } else {
        map.resolve_jobs(&selectors)?
    };
    let mut outputs_by_drv: std::collections::BTreeMap<String, Vec<String>> = Default::default();
    for job in &jobs {
        let Some(drv) = map.jobs.get(job.as_str()) else {
            continue;
        };
        let outputs: Vec<String> = map
            .outputs
            .get(job.as_str())
            .map(|outputs| outputs.values().cloned().collect())
            .unwrap_or_default();
        outputs_by_drv.entry(drv.clone()).or_insert(outputs);
    }

    let report = crate::nix::buildset::push_prebuilt(&outputs_by_drv, &route)?;
    ui::emit(
        &json,
        &CachePush {
            candidates: report.candidates,
            in_cache: report.in_cache,
            unbuilt: report.unbuilt,
            paths: report.push.len(),
        },
        |push| {
            ui::result(format!(
                "{} jobs pushed ({} paths) · {} already cached · {} not built here",
                push.candidates, push.paths, push.in_cache, push.unbuilt
            ));
        },
    )?;
    Ok(CommandStatus::SUCCESS)
}

/// The supervisor spawns the payload verbatim; catching an unspawnable one
/// here fails in the caller's terminal instead of minting a dead run.
pub(crate) fn payload_check(program: &str, on_path: bool) -> Result<()> {
    if on_path {
        return Ok(());
    }
    let own_command = <Cli as clap::CommandFactory>::command()
        .get_subcommands()
        .any(|sub| sub.get_name() == program);
    if own_command {
        return Err(crate::support::error::Error::Request(format!(
            "run start executes its payload verbatim, and `{program}` is a wasinix command, not a binary; name the binary: `wasinix run start -- wasinix {program} ...`"
        )));
    }
    Err(crate::support::error::Error::Request(format!(
        "{program} is not on PATH; the payload is executed verbatim by the run's supervisor"
    )))
}

fn run_command(command: RunCommand) -> Result<CommandStatus> {
    match command {
        RunCommand::Start {
            wait,
            follow,
            command,
        } => {
            payload_check(&command[0], crate::support::env::on_path(&command[0]))?;
            let run_id = runs::start(&command)?;
            // The durable handle first: an observer lost mid-watch still
            // leaves the id on the terminal to rejoin with.
            ui::result(&run_id);
            if follow {
                let run_dir = runs::dir_of(&run_id)?;
                render::watch(&run_dir)?;
                runs::reap(&run_dir)?;
                let run = runs::observed(&run_dir)?;
                return Ok(run.state.exit(run.exit_code));
            }
            if wait {
                let run = runs::wait(&run_id, None)?;
                return Ok(run.state.exit(run.exit_code));
            }
            Ok(CommandStatus::SUCCESS)
        }
        RunCommand::List { active, json } => {
            #[derive(serde::Serialize, serde::Deserialize)]
            struct RunList {
                runs: Vec<runs::Run>,
            }
            impl schema::Document for RunList {
                const KIND: &'static str = "runList";
                const SCHEMA: u32 = 1;
            }
            let mut runs = runs::list()?;
            if active {
                runs.retain(|run| !run.state.is_final());
            }
            ui::emit(&json, &RunList { runs }, |list| {
                let rows: Vec<Vec<String>> = list
                    .runs
                    .iter()
                    .map(|run| {
                        vec![
                            run.run_id.clone(),
                            run.state.to_string(),
                            run.command.join(" "),
                        ]
                    })
                    .collect();
                ui::output(crate::support::table::render(
                    Some(&["id", "state", "command"]),
                    &rows,
                ));
            })?;
            Ok(CommandStatus::SUCCESS)
        }
        RunCommand::Status { run_id, json } => {
            let run_dir = runs::dir_of(&run_id)?;
            runs::reap(&run_dir)?;
            let run = runs::observed(&run_dir)?;
            let snapshot = crate::ci::events::read_snapshot(&run_dir).ok();
            #[derive(serde::Serialize, serde::Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct RunStatus {
                run: runs::Run,
                run_dir: PathBuf,
                #[serde(default, skip_serializing_if = "Option::is_none")]
                snapshot: Option<crate::ci::events::Snapshot>,
            }
            impl schema::Document for RunStatus {
                const KIND: &'static str = "runStatus";
                const SCHEMA: u32 = 1;
            }
            ui::emit(
                &json,
                &RunStatus {
                    run,
                    run_dir,
                    snapshot,
                },
                |status| {
                    let mut parts = vec![status.run.state.to_string()];
                    if let Some(snapshot) = &status.snapshot {
                        parts.push(format!("{} jobs done", snapshot.completed_jobs));
                        if snapshot.failed_jobs > 0 {
                            parts.push(format!("{} failed", snapshot.failed_jobs));
                        }
                        if !snapshot.building.is_empty() {
                            let names: Vec<&str> =
                                snapshot.building.iter().map(|job| job.as_str()).collect();
                            parts.push(format!(
                                "building {}",
                                crate::support::format::some(&names, 3)
                            ));
                        }
                    }
                    ui::result(format!("{run_id}: {}", ui::counts(&parts)));
                },
            )?;
            Ok(CommandStatus::SUCCESS)
        }
        RunCommand::Logs { run_id, follow } => {
            runs::follow_logs(&runs::dir_of(&run_id)?, follow)?;
            Ok(CommandStatus::SUCCESS)
        }
        RunCommand::Report { run_id, json } => {
            let run_dir = runs::dir_of(&run_id)?;
            let path = crate::ci::prepare::report_path(&run_dir);
            let report: crate::ci::report::Report = schema::read(&path)?;
            ui::emit(&json, &report, |report| {
                render::finished_report(report);
            })?;
            Ok(CommandStatus::SUCCESS)
        }
        RunCommand::Failures { run_id, json } => {
            // One document kind either way: full failures from the folded
            // report, or the live snapshot's failure tail when the run has
            // not folded yet.
            #[derive(serde::Serialize, serde::Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct Failures {
                #[serde(default, skip_serializing_if = "std::collections::BTreeMap::is_empty")]
                failures: std::collections::BTreeMap<String, Vec<crate::ci::facts::Failure>>,
                #[serde(default, skip_serializing_if = "Vec::is_empty")]
                recent_failures: Vec<String>,
            }
            impl schema::Document for Failures {
                const KIND: &'static str = "failures";
                const SCHEMA: u32 = 1;
            }
            let run_dir = runs::dir_of(&run_id)?;
            let path = crate::ci::prepare::report_path(&run_dir);
            let document = if path.exists() {
                let report: crate::ci::report::Report = schema::read(&path)?;
                Failures {
                    failures: report.failures,
                    recent_failures: Vec::new(),
                }
            } else {
                Failures {
                    failures: Default::default(),
                    recent_failures: crate::ci::events::read_snapshot(&run_dir)?
                        .recent_failures
                        .into_iter()
                        .map(|job| job.to_string())
                        .collect(),
                }
            };
            ui::emit(&json, &document, |document| {
                for job in &document.recent_failures {
                    ui::result(job);
                }
                for (task, failures) in &document.failures {
                    for failure in failures {
                        let mut parts = vec![format!("{task}: {}", failure.job)];
                        parts.push(failure.cause.to_string());
                        if let Some(message) = &failure.message {
                            parts.push(message.clone());
                        }
                        if let Some(log) = &failure.log {
                            parts.push(log.path.clone());
                        }
                        ui::result(ui::counts(&parts));
                        // The archived tail is the evidence the row points
                        // at; a listing without it sends the reader to gunzip
                        // by hand.
                        if let Some(log) = &failure.log {
                            // Build task ids are <case>.<target>, and the
                            // archive lives under the target's log dir.
                            let (case, target) =
                                task.split_once('.').unwrap_or((task.as_str(), ""));
                            let logs = crate::ci::prepare::logs_dir(&crate::ci::prepare::case_dir(
                                &run_dir, case,
                            ))
                            .join(target);
                            match crate::ci::facts::logs::read_archived(&logs, log, 4_000) {
                                Ok(tail) => {
                                    for line in tail.lines() {
                                        ui::raw(format!("    {line}\n"));
                                    }
                                }
                                Err(error) => {
                                    ui::note(format!("log {} unavailable: {error}", log.path))
                                }
                            }
                        }
                    }
                }
            })?;
            Ok(CommandStatus::SUCCESS)
        }
        RunCommand::Watch { run_id } => {
            let run_dir = runs::dir_of(&run_id)?;
            render::watch(&run_dir)?;
            runs::reap(&run_dir)?;
            let run = runs::observed(&run_dir)?;
            Ok(run.state.exit(run.exit_code))
        }
        RunCommand::Wait { run_id, timeout } => {
            let run = runs::wait(&run_id, timeout.map(std::time::Duration::from_secs))?;
            runs::reap(&runs::dir_of(&run_id)?)?;
            ui::result(format!("{run_id}: {}", run.state));
            Ok(run.state.exit(run.exit_code))
        }
        RunCommand::Cancel { run_id } => {
            // `host:run` is the handle a remote launch prints; a bare id is
            // local. Run ids never contain a colon, so the split is safe.
            match run_id.split_once(':') {
                Some((remote, run)) => {
                    let repo = crate::support::git::repo_root()?;
                    let builder = crate::nix::builder::load(&repo, Some(remote))?;
                    crate::runs::remote::cancel(&builder, run)?;
                }
                None => runs::cancel(&run_id)?,
            }
            Ok(CommandStatus::SUCCESS)
        }
        RunCommand::Supervise { run_dir, command } => {
            runs::supervise(&run_dir, &command)?;
            Ok(CommandStatus::SUCCESS)
        }
    }
}

fn cache_intent(push_cache: bool) -> request::CacheIntent {
    if push_cache {
        request::CacheIntent::Push
    } else {
        request::CacheIntent::Off
    }
}

/// A GitHub runner kills the job at six hours, so a comment bisect is given
/// a smaller budget of its own: it stops with the range narrowed and the
/// report on disk, and the same command run again continues from there.
const COMMENT_BISECT_BUDGET: crate::nix::bisect::Budget = crate::nix::bisect::Budget {
    candidates: 8,
    wall: std::time::Duration::from_secs(4 * 60 * 60),
};

/// Upsert the bisect's one reply. Every tick rewrites the same comment, so
/// a long bisect leaves one current answer rather than a trail.
fn bisect_reply(
    command: &crate::ci::origin::Command,
    body: crate::github::sanitize::Markdown,
) -> Result<()> {
    let client = crate::github::client::Client::new(crate::github::client::token().as_deref());
    let mut registry = crate::github::surfaces::Registry::new(
        &client,
        command.origin.repository.clone(),
        command.origin.pull_request,
        crate::github::surfaces::BOT_AUTHOR,
        crate::support::effects::Effects::Apply,
    );
    registry.upsert(
        &crate::github::surfaces::Surface::CiReportReply {
            comment_id: command.origin.comment_id,
        },
        &[],
        body,
    )?;
    Ok(())
}

/// Run a `/wasinix bisect` and reply with what it found. The answer is a
/// commit, so it never enters the report fold.
fn ci_bisect(
    repo: &std::path::Path,
    command: &crate::ci::origin::Command,
    request: untrusted::BisectCommand,
    run_dir: PathBuf,
) -> Result<CommandStatus> {
    let target = request.target.clone();
    // A candidate is a whole build, so the first answer is hours away. The
    // reply exists before the first one and is rewritten after each, which
    // is also what a budget-stopped run leaves behind.
    let mut progress = |tested: usize| {
        bisect_reply(
            command,
            crate::github::markdown::bisect_progress(&target, tested),
        )
    };
    progress(0)?;
    let bisect_dir = run_dir.join("bisect");
    let report = match bisect::drive(
        repo,
        bisect::Bisect {
            target: request.target,
            good: request.good,
            bad: request.bad,
            first_parent: request.first_parent,
            reverse: request.reverse,
            words: request.words,
            predicate: request.predicate,
            run_dir: bisect_dir.clone(),
            budget: Some(COMMENT_BISECT_BUDGET),
            progress: Some(&mut progress),
        },
    ) {
        Ok(report) => report,
        // What it narrowed before it died is the useful half, and it is on
        // disk: losing it to the generic failure path costs a build apiece.
        Err(error) => {
            if let Some(partial) = crate::nix::bisect::read_report(&bisect_dir) {
                let _ = bisect_reply(
                    command,
                    crate::github::markdown::bisect_reply(
                        &partial,
                        Some(&crate::support::error::brief(&error, 1500)),
                        crate::support::env::github_run_url()?.as_deref(),
                        Some(&crate::github::surfaces::origin_comment_url(
                            &command.origin.repository,
                            command.origin.pull_request,
                            command.origin.comment_id,
                        )),
                    ),
                );
            }
            return Err(error);
        }
    };
    let client = crate::github::client::Client::new(crate::github::client::token().as_deref());
    let mut registry = crate::github::surfaces::Registry::new(
        &client,
        command.origin.repository.clone(),
        command.origin.pull_request,
        crate::github::surfaces::BOT_AUTHOR,
        crate::support::effects::Effects::Apply,
    );
    let origin = crate::github::surfaces::origin_comment_url(
        &command.origin.repository,
        command.origin.pull_request,
        command.origin.comment_id,
    );
    registry.upsert(
        &crate::github::surfaces::Surface::CiReportReply {
            comment_id: command.origin.comment_id,
        },
        &[],
        crate::github::markdown::bisect_reply(
            &report,
            None,
            crate::support::env::github_run_url()?.as_deref(),
            Some(&origin),
        ),
    )?;
    match &report.first_bad {
        Some(rev) => ui::result(format!("first bad {} commit: {rev}", report.target)),
        None => ui::result(format!(
            "{}: budget spent, {} candidates tested",
            report.target,
            report.tests.len()
        )),
    }
    Ok(CommandStatus::SUCCESS)
}

fn ci_command(command: CiCommand) -> Result<CommandStatus> {
    let repo = crate::support::git::repo_root()?;
    match command {
        CiCommand::NixConfig => {
            ui::output(crate::support::nix::nix_config());
            Ok(CommandStatus::SUCCESS)
        }
        CiCommand::Run {
            request,
            run_dir,
            push_cache,
        } => {
            let resolved: crate::ci::types::ResolvedRequest = schema::read(&request)?;
            request::drive(request::Drive {
                repo: &repo,
                source: request::Source::Resolved(resolved),
                run_dir,
                cache: cache_intent(push_cache),
                only: request::TaskFilter::All,
                follow: false,
                finish: request::Finish::Headline,
            })
        }
        CiCommand::Remote {
            request,
            run_dir,
            on,
        } => {
            let builder = crate::nix::builder::load(&repo, on.as_deref())?;
            if !builder.supports(crate::nix::builder::Capability::Host) {
                return Err(crate::support::error::Error::Request(format!(
                    "remote {:?} does not provide the host route",
                    builder.name
                )));
            }
            let request: crate::ci::types::ResolvedRequest = schema::read(&request)?;
            // A shipped launch decides its own cache policy on the host side.
            request::run_on_host(
                &repo,
                &builder,
                request,
                &run_dir,
                request::CacheIntent::Off,
            )
        }
        CiCommand::Observe {
            remote_run_dir,
            run_dir,
            on,
        } => {
            let builder = crate::nix::builder::load(&repo, on.as_deref())?;
            let mut renderer = crate::cli::render::LineRenderer::new();
            let status =
                crate::runs::remote::observe(&builder, &remote_run_dir, &run_dir, &mut |event| {
                    renderer.event(event)
                });
            renderer.finish();
            status
        }
        CiCommand::Prepare { request, run_dir } => {
            let request: crate::ci::types::ResolvedRequest = schema::read(&request)?;
            crate::ci::prepare::prepare_all(&repo, &request, &run_dir)?;
            Ok(CommandStatus::SUCCESS)
        }
        CiCommand::Exec {
            run_dir,
            tasks,
            push_cache,
        } => {
            let only = if tasks.is_empty() {
                request::TaskFilter::All
            } else {
                request::TaskFilter::Tasks(tasks)
            };
            request::drive(request::Drive {
                repo: &repo,
                source: request::Source::Prepared,
                run_dir,
                cache: cache_intent(push_cache),
                only,
                follow: false,
                finish: request::Finish::Headline,
            })
        }
        CiCommand::Publish {
            run_dir,
            surface,
            sha,
            dry_run,
            comment,
            check,
            step_summary,
            baseline,
            reply_to,
            untrusted,
            watch,
            interval,
            failure_logs,
        } => {
            let effects = crate::support::effects::Effects::from_dry_run(dry_run);
            if watch {
                crate::support::error::require(
                    comment || check,
                    "--watch needs --comment or --check",
                )?;
            }
            if baseline {
                // Every built case is worth publishing: keys are the
                // materialized trees, so heads and bases alike serve later
                // runs. A case adopted from a published map is already there.
                let loaded = crate::ci::prepare::load(&run_dir)?;
                for case in loaded.request.cases() {
                    let id = case.case_id();
                    if !matches!(case, crate::ci::types::CaseRef::Build(_)) {
                        continue;
                    }
                    if loaded.preparation.reused.iter().any(|reused| reused == id) {
                        continue;
                    }
                    crate::ci::baseline::publish_from_run(&run_dir, id, effects)?;
                }
            }
            if !comment && !check && step_summary.is_none() {
                return Ok(CommandStatus::SUCCESS);
            }
            let repository = surface.repository(&repo)?;
            // The sha reaches a check-run head and a comment marker; validate
            // it as a revision before it is trusted as either.
            let head_sha = match sha {
                Some(sha) => Some(crate::support::atoms::Rev::parse(&sha)?.full().to_string()),
                None => None,
            };
            let mut target = crate::github::publish::Target {
                repository,
                pull_request: surface.pull_request,
                head_sha,
                run_url: surface.run_url,
                author: surface.author,
                untrusted,
                log_base: None,
            };
            let client =
                crate::github::client::Client::new(crate::github::client::token().as_deref());
            if watch {
                // One tail, two sinks: the same terminal narration `follow`
                // renders, and the throttled surface publisher.
                let mut renderer = crate::cli::render::LineRenderer::new();
                let mut watcher = crate::github::publish::Watcher::new(
                    &client,
                    &target,
                    crate::github::publish::Watch {
                        run_dir: &run_dir,
                        interval: std::time::Duration::from_secs(interval),
                        comment,
                        check,
                        reply_to,
                    },
                    effects,
                );
                crate::ci::events::tail(
                    &run_dir,
                    std::time::Duration::from_millis(500),
                    |fresh| {
                        for event in fresh {
                            renderer.event(event);
                        }
                        watcher.observe(fresh);
                        Ok(())
                    },
                    // A lost run never writes RunFinished; reap notices the
                    // dead supervisor and the observed record says so.
                    || {
                        runs::reap(&run_dir)?;
                        Ok(runs::observed(&run_dir)?.state.is_final())
                    },
                )?;
                renderer.finish();
                return Ok(CommandStatus::SUCCESS);
            }
            let rendered = crate::github::publish::load(&run_dir)?;
            if failure_logs {
                let sha = target.head_sha.clone().ok_or_else(|| {
                    crate::support::error::Error::Request(
                        "--failure-logs needs --sha to name the log prefix".into(),
                    )
                })?;
                target.log_base = crate::github::publish::publish_failure_logs(
                    &run_dir, &rendered, &sha, effects,
                )?;
            }
            if comment {
                if let Some(id) =
                    crate::github::publish::comment(&client, &rendered, &target, reply_to, effects)?
                {
                    ui::fact("report comment", id);
                }
            }
            if check {
                crate::github::publish::check(&client, &rendered, &target, effects)?;
            }
            if let Some(path) = step_summary {
                crate::github::publish::step_summary(&rendered, &target, &path, effects)?;
            }
            Ok(CommandStatus::SUCCESS)
        }
        CiCommand::Origin {
            event,
            allowed_owner,
            github_output,
            out,
        } => {
            use std::io::Write;
            let event: serde_json::Value = crate::support::json::read(&event)?;
            let api = crate::ci::origin::Rest {
                token: crate::github::client::token(),
            };
            let command = crate::ci::origin::authorize(
                &event,
                &api,
                &untrusted::ClapClassifier,
                allowed_owner.as_deref(),
            )?;
            schema::write(&out, &command)?;
            if let Some(path) = github_output {
                let mut file = std::fs::OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&path)
                    .map_err(|e| crate::support::error::io(&path, e))?;
                for line in [
                    format!("kind={}", command.kind),
                    format!("commentId={}", command.origin.comment_id),
                    format!("pullRequest={}", command.origin.pull_request),
                    format!("headSha={}", command.origin.head_sha),
                ] {
                    writeln!(file, "{line}").map_err(|e| crate::support::error::io(&path, e))?;
                }
            }
            ui::fact(
                "authorized",
                format!("{} by {}", command.command, command.origin.actor),
            );
            Ok(CommandStatus::SUCCESS)
        }
        CiCommand::Command {
            origin,
            run_dir,
            push_cache,
        } => {
            let command: crate::ci::origin::Command = schema::read(&origin)?;
            // Before anything that can fail: a run that dies during
            // materialization has no plan and no request, and its report
            // could not say which command it was.
            schema::write(&run_dir.join(crate::runs::ORIGIN_FILE), &command)?;
            let api = crate::ci::origin::Rest {
                token: crate::github::client::token(),
            };
            // Re-verify against live GitHub state: the comment, its author's
            // permission, and the PR head must still be what was authorized.
            crate::ci::origin::verify(
                &command.origin,
                &command.command,
                &api,
                &untrusted::ClapClassifier,
            )?;
            let mut parsed = match untrusted::parse(&command.command)? {
                untrusted::UntrustedCommand::Request(request) => request,
                // A bisect answers with its own reply rather than a CI
                // report: its result is a commit, not a set of job outcomes.
                untrusted::UntrustedCommand::Bisect(bisect) => {
                    return ci_bisect(&repo, &command, bisect, run_dir);
                }
                // The build job carries no write credential; mutations run
                // through the ci mutate / mutate-publish pair.
                untrusted::UntrustedCommand::Mutation(_) => {
                    return crate::support::error::request_error(
                        "mutation commands run through ci mutate, not ci command",
                    );
                }
                // Help is a command like any other: it replies to the comment
                // that asked, rather than erroring into the failure path.
                untrusted::UntrustedCommand::Help => {
                    let client = crate::github::client::Client::new(
                        crate::github::client::token().as_deref(),
                    );
                    let mut registry = crate::github::surfaces::Registry::new(
                        &client,
                        command.origin.repository.clone(),
                        command.origin.pull_request,
                        crate::github::surfaces::BOT_AUTHOR,
                        crate::support::effects::Effects::Apply,
                    );
                    let origin = crate::github::surfaces::origin_comment_url(
                        &command.origin.repository,
                        command.origin.pull_request,
                        command.origin.comment_id,
                    );
                    let body = crate::github::sanitize::Markdown::concat([
                        crate::github::sanitize::Markdown::constant("<sub>"),
                        crate::github::sanitize::Markdown::html_link(
                            "\u{21b3} in reply to this command",
                            &origin,
                        ),
                        crate::github::sanitize::Markdown::constant("</sub>\n\n"),
                        surface::comment_help(),
                    ]);
                    registry.upsert(
                        &crate::github::surfaces::Surface::CiReportReply {
                            comment_id: command.origin.comment_id,
                        },
                        &[],
                        body,
                    )?;
                    return Ok(CommandStatus::SUCCESS);
                }
            };
            parsed.default_from_pr();
            request::drive(request::Drive {
                repo: &repo,
                source: request::Source::Parse {
                    request: parsed,
                    origin: Some(&command.origin),
                },
                run_dir,
                cache: cache_intent(push_cache),
                only: request::TaskFilter::All,
                follow: false,
                finish: request::Finish::Headline,
            })
        }
        CiCommand::Mutate { origin, out_dir } => {
            crate::github::mutation::mutate(&repo, &origin, &out_dir)?;
            Ok(CommandStatus::SUCCESS)
        }
        CiCommand::MutatePublish { out_dir } => {
            crate::github::mutation::mutate_publish(&repo, &out_dir)?;
            Ok(CommandStatus::SUCCESS)
        }
        CiCommand::StepTimings {
            run_id,
            rev,
            repository,
            step_summary,
            publish,
            dry_run,
        } => {
            let run_id = match run_id {
                Some(run_id) => Some(run_id),
                None => crate::support::env::github_run_id()?.and_then(|value| value.parse().ok()),
            };
            let run_id = run_id.ok_or_else(|| {
                crate::support::error::Error::Request(
                    "step timings need --run-id or GITHUB_RUN_ID".into(),
                )
            })?;
            let repository =
                crate::github::surfaces::resolve_repository(repository.as_deref(), &repo)?;
            let rev = match rev {
                Some(rev) => Some(rev),
                None => crate::support::env::github_sha()?,
            };
            let rev = rev
                .map(|rev| crate::support::atoms::Rev::parse(&rev))
                .transpose()?;
            let workflow = crate::support::env::github_workflow()?.unwrap_or_default();
            let timings = crate::ci::steps::collect(
                &crate::github::client::Client::new(None),
                &repository,
                run_id,
                rev,
                &workflow,
            )?;
            if let Some(path) = &step_summary {
                crate::support::fs::append(path, timings.summary().as_bytes())?;
            }
            if publish {
                timings.publish(crate::support::effects::Effects::from_dry_run(dry_run))?;
            }
            crate::support::ui::fact("step timings", format!("{} jobs", timings.jobs.len()));
            Ok(CommandStatus::SUCCESS)
        }
        CiCommand::Reply {
            surface,
            comment_id,
            failures,
        } => {
            let pull_request = surface.pull_request.ok_or_else(|| {
                crate::support::error::Error::Request("a reply needs --pull-request".into())
            })?;
            let repository = surface.repository(&repo)?;
            let origin =
                crate::github::surfaces::origin_comment_url(&repository, pull_request, comment_id);
            let body = crate::github::markdown::failure_reply(
                &failure_tail(&failures),
                surface.run_url.as_deref(),
                Some(&origin),
            );
            let client =
                crate::github::client::Client::new(crate::github::client::token().as_deref());
            let mut registry = crate::github::surfaces::Registry::new(
                &client,
                repository,
                pull_request,
                &surface.author,
                crate::support::effects::Effects::Apply,
            );
            if let Some(id) = registry.upsert(
                &crate::github::surfaces::Surface::CiReportReply { comment_id },
                &[],
                body,
            )? {
                ui::fact("failure reply", id);
            }
            Ok(CommandStatus::SUCCESS)
        }
    }
}

/// The last bytes of whichever failure files exist, transfer chatter
/// dropped, on a char boundary; the reply quotes an excerpt, the Actions
/// run holds the rest.
pub(crate) fn failure_tail(paths: &[PathBuf]) -> String {
    const TAIL_BYTES: usize = 1500;
    let mut detail = String::new();
    for path in paths {
        if let Ok(text) = std::fs::read_to_string(path) {
            for line in text
                .lines()
                .filter(|line| !crate::support::nix::progress_noise(line))
            {
                detail.push_str(line);
                detail.push('\n');
            }
        }
    }
    let mut start = detail.len().saturating_sub(TAIL_BYTES);
    while !detail.is_char_boundary(start) {
        start += 1;
    }
    detail[start..].to_string()
}

/// Completion values for run ids: whatever the local registry holds.
fn run_id_candidates() -> Vec<clap_complete::CompletionCandidate> {
    crate::runs::run_ids()
        .into_iter()
        .map(clap_complete::CompletionCandidate::new)
        .collect()
}

fn run(command: CommandTree) -> Result<CommandStatus> {
    match command {
        CommandTree::Completions { shell } => {
            // Registration only: values complete at runtime through the
            // dynamic engine, so job names and run ids stay live.
            let name = shell.to_string();
            let shells = clap_complete::env::Shells::builtins();
            let Some(completer) = shells.completer(&name) else {
                return crate::support::error::request_error(format!(
                    "no dynamic completion for {name}"
                ));
            };
            completer
                .write_registration(
                    "COMPLETE",
                    "wasinix",
                    "wasinix",
                    "wasinix",
                    &mut std::io::stdout(),
                )
                .map_err(|e| crate::support::error::io(std::path::Path::new("<stdout>"), e))?;
            Ok(CommandStatus::SUCCESS)
        }
        CommandTree::Build(args) => request::run_build(&crate::support::git::repo_root()?, args),
        CommandTree::Spot(args) => request::run_spot(&crate::support::git::repo_root()?, args),
        CommandTree::Diff(args) => request::run_diff(&crate::support::git::repo_root()?, args),
        CommandTree::Bisect(args) => bisect::run_bisect(&crate::support::git::repo_root()?, args),
        CommandTree::Jobs { pattern, json } => jobs_command(pattern, json),
        CommandTree::Doctor => doctor(),
        CommandTree::Timings(args) => timings::run(args),
        CommandTree::Cache(command) => cache_command(command),
        CommandTree::Run(command) => run_command(command),
        CommandTree::Cargo(command) => registries::run_cargo(command),
        CommandTree::Wasmer(command) => registries::run_wasmer(command),
        CommandTree::Python(command) => registries::run_python(command),
        CommandTree::Publish { dry_run } => {
            registries::run_meta_publish(crate::support::effects::Effects::from_dry_run(dry_run))
        }
        CommandTree::Preview(args) => preview::run(args),
        CommandTree::Serve {
            mint,
            index,
            server,
            webcs,
            exec,
        } => registries::run_meta_serve(mint, index, server, webcs, exec),
        CommandTree::Update(args) => update::run_update(args),
        CommandTree::Versions(command) => update::run_versions(command),
        CommandTree::Remote(command) => remote::run(command),
        CommandTree::Ci(command) => ci_command(command),
        CommandTree::Regenerate | CommandTree::Fmt => {
            crate::support::error::request_error("this command is comment only")
        }
        CommandTree::SurfaceHelp => {
            use clap::CommandFactory;
            ui::output(<Cli as CommandFactory>::command().render_long_help());
            Ok(CommandStatus::SUCCESS)
        }
    }
}

pub fn main() -> std::process::ExitCode {
    // Dynamic shell completion: a request re-enters the binary with COMPLETE
    // set and exits here; `completions <shell>` prints the registration.
    clap_complete::CompleteEnv::with_factory(<Cli as clap::CommandFactory>::command).complete();
    let cli = Cli::parse();
    ui::set_verbosity(if cli.quiet {
        ui::Verbosity::Quiet
    } else if cli.verbose {
        ui::Verbosity::Verbose
    } else {
        ui::Verbosity::Normal
    });
    crate::support::terminal::set_color_choice(match cli.color {
        ColorMode::Auto => crate::support::terminal::ColorChoice::Auto,
        ColorMode::Always => crate::support::terminal::ColorChoice::Always,
        ColorMode::Never => crate::support::terminal::ColorChoice::Never,
    });
    match run(cli.command) {
        Ok(status) => status.into(),
        Err(error) => {
            ui::report_error(&error);
            error.status().into()
        }
    }
}
