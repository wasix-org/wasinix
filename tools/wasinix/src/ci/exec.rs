//! Execute a CI plan. Every phase reads and writes only the run directory and
//! leaves a typed fragment behind, so a report can be folded from whatever
//! finished; progress is recorded on the run's event stream, never printed
//! into it.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::ci::compare::JobStatuses;
use crate::ci::evalmap::EvalMap;
use crate::ci::events::{Event, Tracker};
use crate::ci::facts;
use crate::ci::plan::{BuildTarget, Phase, REPOSITORY_LABEL, REPOSITORY_TASK, Task, TaskKind};
use crate::ci::prepare::{Loaded, case_dir, fragments_dir};
use crate::ci::report::{Fragment, FragmentData, LogExcerpt};
use crate::ci::types::{Build, CaseRef, RequestAction, ResolvedRequest, RevSource, Spot};
use crate::ci::workspace::{PATCH_FILE, reproduced_worktree};
use crate::nix::evaljobs;
use crate::nix::route::Route;
use crate::support::atoms::{Bytes, DurationSecs, JobAddr, JobStatus, TaskStatus};
use crate::support::error::{Error, Result, io, request_error};
use crate::support::process::CommandStatus;
use crate::support::schema;
use crate::support::time::unix_secs;

pub struct Context<'a> {
    /// The orchestrator checkout. The worktrees hold the revision under test
    /// and must never supply the code that builds it.
    pub runner_root: &'a Path,
    pub run_dir: &'a Path,
    /// Whether builds may sign and push to the cache; the signing key still
    /// has to be present and valid.
    pub push_cache: bool,
}

impl Context<'_> {
    fn fragments(&self) -> PathBuf {
        fragments_dir(self.run_dir)
    }

    fn fragment_path(&self, task_id: &str) -> PathBuf {
        self.fragments().join(format!("{task_id}.json"))
    }
}

const EXCERPT_LINES: usize = 120;

#[derive(Default)]
struct Artifacts {
    files: BTreeMap<PathBuf, u64>,
    total_bytes: u64,
}

impl Artifacts {
    fn record(&mut self, path: &Path) -> Result<()> {
        let metadata = std::fs::metadata(path).map_err(|error| io(path, error))?;
        let previous = self.files.get(path).copied().unwrap_or(0);
        let total_bytes = self
            .total_bytes
            .checked_sub(previous)
            .and_then(|total| total.checked_add(metadata.len()))
            .ok_or_else(|| Error::Failure("artifact byte count overflowed u64".to_string()))?;
        self.files.insert(path.to_path_buf(), metadata.len());
        self.total_bytes = total_bytes;
        Ok(())
    }

    fn record_log(&mut self, path: &Path) -> Result<()> {
        self.record(path)?;
        self.record(&crate::support::log::retention_path(path))
    }

    fn add_shared(&mut self, bytes: u64) -> Result<()> {
        self.total_bytes = self.total_bytes.checked_add(bytes).ok_or_else(|| {
            Error::Failure("shared artifact byte count overflowed u64".to_string())
        })?;
        Ok(())
    }

    fn bytes(&self) -> u64 {
        self.total_bytes
    }
}

#[cfg(test)]
mod artifact_tests {
    use super::Artifacts;

    #[test]
    fn accounting_tracks_owned_files_once() {
        let scratch = crate::support::fs::Scratch::create("wasinix-test").unwrap();
        let path = scratch.path().join("artifact");
        std::fs::write(&path, b"first").unwrap();
        let mut artifacts = Artifacts::default();
        artifacts.record(&path).unwrap();
        artifacts.record(&path).unwrap();
        artifacts.add_shared(2).unwrap();
        assert_eq!(artifacts.bytes(), 7);

        std::fs::write(&path, b"replacement").unwrap();
        artifacts.record(&path).unwrap();
        assert_eq!(artifacts.bytes(), 13);
    }

    #[test]
    fn task_accounting_does_not_scan_the_run_tree() {
        let source = include_str!("exec.rs");
        let scan = ["tree_", "bytes("].concat();
        assert!(!source.contains(&scan));
    }

    #[test]
    fn authoritative_evaluation_reuses_the_input_catalog() {
        let source = include_str!("exec.rs");
        let input = source
            .split("\nfn eval_inputs(")
            .nth(1)
            .unwrap()
            .split("pub(crate) fn selector_catalog(")
            .next()
            .unwrap();
        let evaluation = source
            .split("\nfn evaluate(")
            .nth(1)
            .unwrap()
            .split("/// Resolve a spot case")
            .next()
            .unwrap();
        assert!(input.contains("selector_catalog_path"));
        assert!(input.contains("support::json::write"));
        assert!(evaluation.contains("selector_catalog_path"));
        assert!(!evaluation.contains("selector_catalog(worktree"));
    }
}

/// The tail of a log as fragment content. The full file stays in the run
/// directory; the fragment carries what a report can show inline.
fn excerpt(path: &Path) -> LogExcerpt {
    let text = std::fs::read_to_string(path).unwrap_or_default();
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(EXCERPT_LINES);
    LogExcerpt {
        lines: lines[start..].iter().map(|line| line.to_string()).collect(),
        truncated: start > 0,
    }
}

fn excerpt_of(text: &str) -> LogExcerpt {
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(EXCERPT_LINES);
    LogExcerpt {
        lines: lines[start..].iter().map(|line| line.to_string()).collect(),
        truncated: start > 0,
    }
}

fn repository_checks(
    ctx: &Context,
    worktree: &Path,
    case_id: &str,
    route: &Route,
    artifacts: &mut Artifacts,
) -> Result<Fragment> {
    use std::io::Write;

    let _lease = route.acquire()?;
    let log_path = crate::ci::prepare::logs_dir(&case_dir(ctx.run_dir, case_id))
        .join(REPOSITORY_TASK)
        .join("flake-check.log");
    let log = crate::support::log::SharedLog::create_followed(&log_path)?;
    let copy = |mut stream: Box<dyn std::io::Read + Send>,
                mut log: crate::support::log::SharedLog| {
        std::io::copy(&mut stream, &mut log).map_err(|error| io(&log_path, error))?;
        log.flush().map_err(|error| io(&log_path, error))
    };
    let completion = crate::support::nix::Invocation::flake("flake check", "path:.")
        .arg("--print-build-logs")
        .workdir(worktree)
        .timeout(route.limits()?.timeout)
        .route(route)?
        .run_piped(
            |stream| copy(stream, log.clone()),
            |stream| copy(stream, log.clone()),
        )?;
    let (status, timed_out) = match completion {
        crate::support::tools::Completion::Finished(status) => (status, false),
        crate::support::tools::Completion::TimedOut(status) => (status, true),
    };
    log.finish()?;
    artifacts.record_log(&log_path)?;
    let success = status.success() && !timed_out;
    let headline = if timed_out {
        "repository checks timed out"
    } else if success {
        "repository checks passed"
    } else {
        "repository checks failed"
    };
    let mut fragment = Fragment::new(
        format!("{case_id}.{REPOSITORY_TASK}"),
        format!("{case_id}: {REPOSITORY_LABEL}"),
        TaskKind::Validation,
        if success {
            TaskStatus::Success
        } else {
            TaskStatus::Failure
        },
        headline,
    );
    if !success {
        fragment = fragment.with_data(FragmentData::Log(excerpt(&log_path)));
    }
    Ok(fragment)
}

/// Complete one online evaluation before the authoritative offline one.
fn eval_inputs(
    ctx: &Context,
    worktree: &Path,
    case: &Build<RevSource>,
    route: &Route,
    artifacts: &mut Artifacts,
) -> Result<Fragment> {
    let _lease = route.acquire()?;
    let case_id = case.case_id();
    let logs = crate::ci::prepare::logs_dir(&case_dir(ctx.run_dir, case_id)).join("eval-inputs");
    let attr = crate::support::nix::active_project_installable("ci.jobs");
    let selector_catalog = selector_catalog(worktree, route)?;
    let catalog_path = crate::ci::prepare::selector_catalog_path(&case_dir(ctx.run_dir, case_id));
    crate::support::json::write(&catalog_path, &selector_catalog)?;
    artifacts.record(&catalog_path)?;
    let catalog = selector_catalog.into_map();
    let selected: Vec<String> = crate::ci::compare::selected(case, &catalog)?
        .into_iter()
        .collect();
    let jobs_path = logs.join("jobs.jsonl");
    let evaluate_log = logs.join("evaluate.log");
    let mut failure: Option<(String, PathBuf)> = None;
    let evaluation = evaljobs::run(&evaljobs::RunRequest {
        workdir: worktree,
        flake: &attr,
        jobs_path: &jobs_path,
        stderr_log: &evaluate_log,
        offline: false,
        // Warming inputs only needs the drv paths; a per-job cache query
        // over thousands of jobs is the eval-inputs bottleneck and buys
        // nothing here.
        check_cache: false,
        selected: Some(&selected),
        job_errors: evaljobs::JobErrors::FailFast,
        route,
    })?;
    artifacts.record(&jobs_path)?;
    artifacts.record_log(&evaluate_log)?;
    let status = match evaluation {
        Some(error) => {
            failure = Some((error, evaluate_log.clone()));
            CommandStatus::FAILURE
        }
        None => CommandStatus::SUCCESS,
    };
    let mut fragment = Fragment::new(
        format!("{case_id}.eval-inputs"),
        format!("{case_id}: Preparing evaluation inputs"),
        TaskKind::Eval,
        if status.is_success() {
            TaskStatus::Success
        } else {
            TaskStatus::Failure
        },
        failure
            .as_ref()
            .map(|(headline, _)| headline.as_str())
            .unwrap_or("evaluation inputs are ready"),
    );
    if let Some((_, log)) = &failure {
        fragment = fragment.with_data(FragmentData::Log(excerpt(log)));
    }
    Ok(fragment)
}

pub(crate) fn selector_catalog(
    worktree: &Path,
    route: &Route,
) -> Result<crate::ci::evalmap::SelectorCatalog> {
    let bytes = crate::support::nix::Invocation::flake(
        "eval",
        crate::support::nix::active_project_installable("ci.catalog"),
    )
    .json()
    .workdir(worktree)
    .timeout(route.limits()?.timeout)
    .route(route)?
    .checked_output("the CI selector catalog")?;
    let catalog: crate::ci::evalmap::SelectorCatalog =
        serde_json::from_slice(&bytes).map_err(|source| Error::Json {
            path: "<ci.catalog>".into(),
            source,
        })?;
    let expected = crate::support::schema::project_version();
    if catalog.schema_version != expected {
        return request_error(format!(
            "CI catalog uses Wasinix project schema {}; this wasinix supports schema {expected}",
            catalog.schema_version
        ));
    }
    Ok(catalog)
}

fn require_project_schema(worktree: &Path, route: &Route) -> Result<()> {
    let bytes = crate::support::nix::Invocation::flake(
        "eval",
        crate::support::nix::active_project_installable("schemaVersion"),
    )
    .json()
    .offline()
    .workdir(worktree)
    .timeout(route.limits()?.timeout)
    .route(route)?
    .checked_output("the Wasinix project schema version")?;
    let found: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|source| Error::Json {
            path: "<schemaVersion>".into(),
            source,
        })?;
    let expected = crate::support::schema::project_version();
    if found.as_u64() != Some(expected) {
        return request_error(format!(
            "unsupported Wasinix project schema {found}; this wasinix supports schema {expected}"
        ));
    }
    Ok(())
}

fn evaluate(
    ctx: &Context,
    worktree: &Path,
    case: &Build<RevSource>,
    route: &Route,
    artifacts: &mut Artifacts,
) -> Result<Fragment> {
    let _lease = route.acquire()?;
    require_project_schema(worktree, route)?;
    let case_id = case.case_id();
    let maps = crate::ci::prepare::maps_dir(&case_dir(ctx.run_dir, case_id));
    let attr = crate::support::nix::active_project_installable("ci.jobs");
    let catalog: crate::ci::evalmap::SelectorCatalog = crate::support::json::read(
        &crate::ci::prepare::selector_catalog_path(&case_dir(ctx.run_dir, case_id)),
    )?;
    let catalog = catalog.into_map();
    let selected: Vec<String> = crate::ci::compare::selected(case, &catalog)?
        .into_iter()
        .collect();
    let eval_log = maps.join("eval.log");
    let jobs_path = crate::ci::prepare::eval_jobs_path(&case_dir(ctx.run_dir, case_id));
    let evaluation = evaljobs::run(&evaljobs::RunRequest {
        workdir: worktree,
        flake: &attr,
        jobs_path: &jobs_path,
        stderr_log: &eval_log,
        offline: true,
        // Offline, so a cache-status query cannot reach a substituter; the
        // build's --skip-cached decides what to rebuild instead.
        check_cache: false,
        selected: Some(&selected),
        job_errors: evaljobs::JobErrors::Collect,
        route,
    })?;
    artifacts.record(&jobs_path)?;
    artifacts.record_log(&eval_log)?;
    if let Some(error) = evaluation {
        // No map is written: a broken evaluation must never become a base
        // for someone else to diff against.
        return Ok(Fragment::new(
            format!("{case_id}.eval"),
            format!("{case_id}: Evaluating jobs"),
            TaskKind::Eval,
            TaskStatus::Failure,
            "could not evaluate CI jobs",
        )
        .with_data(FragmentData::Log(excerpt_of(&error))));
    }

    let jobs = evaljobs::parse_file(&crate::support::fs::read_to_string(&jobs_path)?)?;
    let mut mapping = EvalMap::from_jobs(case.source.rev.clone(), &jobs);
    mapping.attach_catalog(catalog);
    let map_path = crate::ci::prepare::eval_map_path(&case_dir(ctx.run_dir, case_id));
    schema::write(&map_path, &mapping)?;
    artifacts.record(&map_path)?;
    mapping.record_completions();

    let omitted_by_tags: BTreeMap<String, usize> = mapping
        .omitted_by_tags(&case.enabled_tags)
        .into_iter()
        .map(|(tag, jobs)| (tag, jobs.len()))
        .collect();
    // Everything the evaluation decided, so "my job is not in the build"
    // has an answer here rather than in the log.
    let mut parts = vec![format!("{} jobs", mapping.jobs.len())];
    if !mapping.errors.is_empty() {
        parts.push(format!("{} eval errors", mapping.errors.len()));
    }
    let omitted: usize = omitted_by_tags.values().sum();
    if omitted > 0 {
        parts.push(format!("{omitted} omitted by tags"));
    }
    let headline = crate::support::ui::counts(&parts);
    Ok(Fragment::new(
        format!("{case_id}.eval"),
        format!("{case_id}: Evaluating jobs"),
        TaskKind::Eval,
        TaskStatus::Success,
        headline,
    )
    .with_data(FragmentData::Eval(crate::ci::report::EvalSummary {
        job_count: mapping.jobs.len(),
        error_count: mapping.errors.len(),
        omitted_by_tags,
        base_rev: None,
    })))
}

/// Resolve a spot case's splice and print its build counts without building:
/// the answer to "how much of this run is my change vs an uncached base".
pub fn spot_probe(ctx: &Context, case: &Spot<RevSource>) -> Result<()> {
    let case_id = case.case_id.as_deref().unwrap_or("case");
    let route = Route::from_on(ctx.runner_root, case.on.as_deref())?;
    let patch = case_dir(ctx.run_dir, case_id)
        .join("prepared")
        .join(PATCH_FILE);
    let worktree = reproduced_worktree(ctx.runner_root, &case.source, &patch)?;
    let mapping = {
        let _lease = route.acquire()?;
        selector_catalog(worktree.path(), &route)?.into_map()
    };
    crate::nix::spot::build(
        ctx.runner_root,
        worktree.path(),
        &crate::nix::spot::Options {
            targets: mapping.resolve_spot_targets(&case.targets)?,
            base: case
                .base
                .clone()
                .unwrap_or_else(|| case.source.rev.full().to_string()),
            sources: mapping.resolve_packages(&case.from_source)?,
            dry_run: true,
            nix_args: Vec::new(),
        },
        &route,
    )?;
    Ok(())
}

/// Run a spot case and lay its outcome out like a built case, so a diff can
/// compare it over the shared target coverage.
fn spot(
    ctx: &Context,
    worktree: &Path,
    case_id: &str,
    case: &Spot<RevSource>,
    route: &Route,
    artifacts: &mut Artifacts,
) -> Result<Fragment> {
    let mapping = {
        let _lease = route.acquire()?;
        selector_catalog(worktree, route)?.into_map()
    };
    let targets = mapping.resolve_spot_targets(&case.targets)?;
    let sources = mapping.resolve_packages(&case.from_source)?;
    let result = crate::nix::spot::build(
        ctx.runner_root,
        worktree,
        &crate::nix::spot::Options {
            targets,
            base: case
                .base
                .clone()
                .unwrap_or_else(|| case.source.rev.full().to_string()),
            sources,
            dry_run: false,
            nix_args: Vec::new(),
        },
        route,
    )?;

    let paths = case_dir(ctx.run_dir, case_id);
    let jobs: BTreeMap<JobAddr, String> = result
        .targets
        .iter()
        .map(|target| {
            (
                JobAddr(format!("packages.wasix.{}", target.target)),
                target.spliced_drv_path.clone(),
            )
        })
        .collect();
    let job_status = if result.status.is_success() {
        JobStatus::Success
    } else {
        JobStatus::Failure
    };
    let status_path = crate::ci::prepare::status_path(&paths);
    schema::write(
        &status_path,
        &JobStatuses {
            statuses: jobs.keys().map(|job| (job.clone(), job_status)).collect(),
        },
    )?;
    artifacts.record(&status_path)?;
    let map_path = crate::ci::prepare::eval_map_path(&paths);
    schema::write(
        &map_path,
        &EvalMap {
            rev: Some(case.source.rev.clone()),
            jobs,
            ..EvalMap::default()
        },
    )?;
    artifacts.record(&map_path)?;
    Ok(Fragment::new(
        format!("{case_id}.spot"),
        format!("{case_id}: Spot"),
        TaskKind::Spot,
        if result.status.is_success() {
            TaskStatus::Success
        } else {
            TaskStatus::Failure
        },
        if result.status.is_success() {
            "spot build passed"
        } else {
            "spot build failed"
        },
    ))
}

struct BuildSpec {
    task_id: String,
    label: String,
    kind: TaskKind,
    case: String,
    target: BuildTarget,
    jobs: Vec<String>,
    on: Option<String>,
}

/// One union job's outcome, keyed `case::name`. `None` status is a job the
/// build never reported, which the junit projection records as incomplete.
pub(crate) struct JobState {
    pub(crate) drv: String,
    pub(crate) status: Option<JobStatus>,
    pub(crate) duration: Option<f64>,
    pub(crate) error: Option<String>,
}

fn target_jobs(
    case: &Build<RevSource>,
    target: BuildTarget,
    mapping: &EvalMap,
) -> Result<Vec<String>> {
    if target == BuildTarget::Jobs {
        let mut jobs = mapping.resolve_enabled_jobs(&case.requested_jobs(), &case.enabled_tags)?;
        mapping.filter_jobs(&mut jobs, &case.source_filters())?;
        return Ok(jobs);
    }
    let mut jobs: Vec<String> = mapping
        .sets
        .get(target.as_str())
        .into_iter()
        .flatten()
        .filter(|job| mapping.tag_enabled(job, &case.enabled_tags))
        .cloned()
        .collect();
    mapping.filter_jobs(&mut jobs, &case.source_filters())?;
    Ok(jobs)
}

pub(crate) fn cached_jobs(path: &Path) -> Result<BTreeSet<String>> {
    Ok(
        evaljobs::parse_file(&crate::support::fs::read_to_string(path)?)?
            .iter()
            .filter(|job| job.cache_status.as_deref() == Some("cached"))
            .map(evaljobs::EvalJob::name)
            .collect(),
    )
}

/// Apply one build stream result. A BUILD result marks every union
/// job sharing the derivation; an EVAL result only marks failures, since a
/// successful evaluation says nothing about the build. First report wins, so
/// each job finishes on the event stream exactly once.
pub(crate) fn record_result(
    value: &Value,
    jobs: &mut BTreeMap<String, JobState>,
    tracker: &mut Tracker,
) -> Result<()> {
    let Some(kind) = value["type"].as_str() else {
        return Ok(());
    };
    if !matches!(kind, "BUILD" | "EVAL") {
        return Ok(());
    }
    let Some(attr) = value["attr"].as_str().map(crate::nix::evaljobs::attr_name) else {
        return Ok(());
    };
    if !attr.contains("::") {
        return Ok(());
    }
    let success = value["success"].as_bool().unwrap_or(false);
    if kind == "EVAL" && success {
        return Ok(());
    }
    let drv = jobs
        .get(&attr)
        .map(|job| job.drv.clone())
        .filter(|drv| !drv.is_empty());
    let status = if success {
        JobStatus::Success
    } else {
        JobStatus::Failure
    };
    let matched: Vec<String> = jobs
        .iter()
        .filter(|(key, job)| {
            key.as_str() == attr.as_str()
                || (kind == "BUILD" && drv.as_deref() == Some(job.drv.as_str()))
        })
        .filter(|(_, job)| job.status.is_none())
        .map(|(key, _)| key.clone())
        .collect();
    for key in matched {
        let job = jobs.get_mut(&key).expect("key was just collected");
        job.status = Some(status);
        job.duration = value["duration"].as_f64();
        job.error = (!success).then(|| {
            value["error"]
                .as_str()
                .unwrap_or("build failed")
                .to_string()
        });
        tracker.record(Event::JobFinished {
            at: unix_secs(),
            job: JobAddr(key),
            status,
            cached: value["cached"].as_bool().unwrap_or(false),
            duration_seconds: value["duration"].as_f64().map(DurationSecs),
            error: job.error.clone(),
        })?;
    }
    Ok(())
}

/// A build stream line announcing that Nix started a top-level job. The build
/// observer translates derivation paths back to these union keys.
pub(crate) fn scheduled_attr(line: &str) -> Option<String> {
    line.strip_prefix("  building ")
        .map(str::trim)
        .map(crate::nix::evaljobs::attr_name)
        .filter(|attr| !attr.is_empty())
}

/// Keeps the event stream alive and honest during a long build: heartbeats at
/// most every few minutes, and one warning when output goes quiet.
struct Liveness {
    stall_after: Duration,
    last_activity: Instant,
    last_heartbeat: Instant,
    warned: bool,
}

impl Liveness {
    fn new(stall_after: Duration) -> Liveness {
        Liveness {
            stall_after,
            last_activity: Instant::now(),
            last_heartbeat: Instant::now(),
            warned: false,
        }
    }

    fn activity(&mut self) {
        self.last_activity = Instant::now();
        self.warned = false;
    }

    fn heartbeat(
        &mut self,
        tracker: &mut Tracker,
        realising: &std::collections::BTreeSet<String>,
        recent_deps: &[String],
    ) -> Result<()> {
        // One heartbeat a minute carries current detail to every observer;
        // each observer's renderer owns its liveness clock.
        // Only when no job derivation is in flight: the job names carry
        // the story otherwise, and dependencies are detail.
        let detail = (realising.is_empty() && !recent_deps.is_empty()).then(|| {
            format!(
                "dependencies: {}",
                crate::support::format::some(recent_deps, 3)
            )
        });
        if self.last_heartbeat.elapsed() >= Duration::from_secs(60) {
            tracker.record(Event::Heartbeat {
                at: unix_secs(),
                detail,
            })?;
            self.last_heartbeat = Instant::now();
        }
        if !self.warned && self.last_activity.elapsed() >= self.stall_after {
            self.warned = true;
            let names: Vec<&str> = realising.iter().map(String::as_str).collect();
            let waiting = if names.is_empty() {
                String::new()
            } else {
                format!("; realising: {}", crate::support::format::some(&names, 5))
            };
            tracker.record(Event::Warning {
                at: unix_secs(),
                message: format!(
                    "no build output for {} seconds{waiting}",
                    self.last_activity.elapsed().as_secs()
                ),
            })?;
        }
        Ok(())
    }
}

/// Split the union junit back into one case-and-target file, backfilling
/// selected jobs the build never reported so absence reads as failure, never
/// as clean.
pub(crate) fn project_junit(
    source: &Path,
    destination: &Path,
    case_id: &str,
    selected: &[String],
    jobs: &BTreeMap<String, JobState>,
) -> Result<()> {
    let prefix = format!("{case_id}::");
    let selected_set: BTreeSet<&str> = selected.iter().map(String::as_str).collect();
    // Build cases only: eval errors are compared separately and must
    // never read as build failures.
    let mut cases: Vec<facts::junit::Case> =
        facts::junit::parse_junits(&[source.to_path_buf()], false)
            .unwrap_or_default()
            .into_iter()
            .filter_map(|mut case| {
                if case.class != "Build" {
                    return None;
                }
                let name = case.attr.strip_prefix(&prefix)?;
                if !selected_set.contains(name) {
                    return None;
                }
                case.attr = name.to_string();
                Some(case)
            })
            .collect();
    for name in selected {
        if cases
            .iter()
            .any(|case| &case.attr == name && case.class == "Build")
        {
            continue;
        }
        let state = jobs.get(&format!("{case_id}::{name}"));
        let success = state.is_some_and(|job| job.status == Some(JobStatus::Success));
        let mut case = facts::junit::Case::new(name.clone(), "Build".to_string());
        case.duration = state.and_then(|job| job.duration).unwrap_or_default();
        if !success {
            case.message = Some(
                state
                    .and_then(|job| job.error.clone())
                    .unwrap_or_else(|| "build did not complete".to_string()),
            );
        }
        cases.push(case);
    }
    cases.sort_by(|a, b| a.attr.cmp(&b.attr).then_with(|| a.class.cmp(&b.class)));
    if let Some(parent) = destination.parent() {
        crate::support::fs::create_dir_all(parent)?;
    }
    crate::support::fs::write(destination, facts::junit::write_junit(&cases).as_bytes())
}

fn load_map(paths: &Path) -> Result<EvalMap> {
    schema::read(&crate::ci::prepare::eval_map_path(paths))
}

fn group_dir(on: Option<&str>) -> String {
    on.unwrap_or("default").replace([':', '/'], "-")
}

fn build_process_diagnostic(message: String, affected_jobs: Vec<JobAddr>) -> facts::Diagnostic {
    facts::Diagnostic {
        severity: if affected_jobs.is_empty() {
            facts::DiagnosticSeverity::Warning
        } else {
            facts::DiagnosticSeverity::Error
        },
        title: facts::BUILD_PROCESS_ERROR_TITLE.to_string(),
        message,
        affected_jobs,
    }
}

fn find_build_case<'a>(
    request: &'a ResolvedRequest,
    case_id: &str,
) -> Result<&'a Build<RevSource>> {
    request
        .cases()
        .into_iter()
        .find(|case| case.case_id() == case_id)
        .and_then(|case| match case {
            CaseRef::Build(build) => Some(build),
            CaseRef::Spot(_) => None,
        })
        .ok_or_else(|| Error::Request(format!("unknown build case {case_id:?}")))
}

/// Run every planned build as one prefixed union per placement, so shared
/// derivations between cases build once.
fn run_build_tasks(
    ctx: &Context,
    request: &ResolvedRequest,
    tasks: &[Task],
    broken: &[String],
    tracker: &mut Tracker,
) -> Result<CommandStatus> {
    let mut specs = Vec::new();
    let mut maps: BTreeMap<String, EvalMap> = BTreeMap::new();
    for task in tasks {
        let Phase::Build { set } = task.phase else {
            continue;
        };
        if broken.contains(&task.case) {
            start_task(tracker, &task.task_id, &task.label, None)?;
            finish_task(
                ctx,
                tracker,
                Fragment::new(
                    task.task_id.clone(),
                    task.label.clone(),
                    task.kind,
                    TaskStatus::Skipped,
                    "evaluation failed for this case",
                ),
                None,
            )?;
            continue;
        }
        let case = find_build_case(request, &task.case)?;
        if !maps.contains_key(&task.case) {
            maps.insert(
                task.case.clone(),
                load_map(&case_dir(ctx.run_dir, &task.case))?,
            );
        }
        let mapping = &maps[&task.case];
        specs.push(BuildSpec {
            task_id: task.task_id.clone(),
            label: task.label.clone(),
            kind: task.kind,
            case: task.case.clone(),
            target: set,
            jobs: target_jobs(case, set, mapping)?,
            on: case.on.clone(),
        });
    }
    if specs.is_empty() {
        return Ok(CommandStatus::SUCCESS);
    }

    let mut jobs: BTreeMap<String, JobState> = BTreeMap::new();
    for (case_id, mapping) in &maps {
        let selected: BTreeSet<&String> = specs
            .iter()
            .filter(|spec| &spec.case == case_id)
            .flat_map(|spec| spec.jobs.iter())
            .collect();
        let cached = cached_jobs(&case_dir(ctx.run_dir, case_id).join("maps/eval-jobs.jsonl"))?;
        for name in selected {
            let key = format!("{case_id}::{name}");
            let cached = cached.contains(name);
            jobs.insert(
                key.clone(),
                JobState {
                    drv: mapping.jobs.get(name.as_str()).cloned().unwrap_or_default(),
                    status: cached.then_some(JobStatus::Success),
                    duration: None,
                    error: None,
                },
            );
            if cached {
                tracker.record(Event::JobFinished {
                    at: unix_secs(),
                    job: JobAddr(key),
                    status: JobStatus::Success,
                    cached: true,
                    duration_seconds: None,
                    error: None,
                })?;
            }
        }
    }
    for spec in &specs {
        start_task(tracker, &spec.task_id, &spec.label, Some(spec.jobs.len()))?;
    }

    let mut groups: BTreeMap<Option<String>, Vec<String>> = BTreeMap::new();
    for spec in &specs {
        let cases = groups.entry(spec.on.clone()).or_default();
        if !cases.contains(&spec.case) {
            cases.push(spec.case.clone());
        }
    }
    let hard_timeout = crate::support::env::build_timeout()?;
    let stall_after = crate::support::env::stall_timeout()?.unwrap_or(Duration::from_secs(300));
    let cutoff = std::time::SystemTime::now();

    let mut worst = CommandStatus::SUCCESS;
    let mut results: BTreeMap<String, PathBuf> = BTreeMap::new();
    let mut union_logs: Vec<PathBuf> = Vec::new();
    let mut build_process_errors: BTreeMap<String, String> = BTreeMap::new();
    let mut union_artifacts = Artifacts::default();
    // Merged across placement groups: one task's jobs can span builders.
    let mut plan = crate::nix::buildset::PlanCensus::new();
    let union_started = Instant::now();
    for (on, cases) in groups {
        let case_ids = cases.clone();
        let group_task_ids: Vec<String> = specs
            .iter()
            .filter(|spec| case_ids.contains(&spec.case))
            .map(|spec| spec.task_id.clone())
            .collect();
        let route = Route::from_on(ctx.runner_root, on.as_deref())?;
        let _lease = route.acquire()?;
        let mut union_cases = Vec::new();
        for case_id in &cases {
            let selected: BTreeSet<String> = specs
                .iter()
                .filter(|spec| &spec.case == case_id)
                .flat_map(|spec| spec.jobs.iter().cloned())
                .collect();
            union_cases.push(crate::nix::buildset::UnionCase {
                id: case_id.clone(),
                jobs_file: case_dir(ctx.run_dir, case_id).join("maps/eval-jobs.jsonl"),
                jobs: selected.into_iter().collect(),
            });
        }
        let build_dir = ctx.run_dir.join("build").join(group_dir(on.as_deref()));
        union_logs.push(build_dir.join("build-union.log"));
        for case in &union_cases {
            results.insert(case.id.clone(), build_dir.join("results.xml"));
        }
        let mut liveness = Liveness::new(stall_after);
        let mut realising: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
        let result_file = build_dir.join("results.xml");
        let status = crate::nix::buildset::build_union(
            crate::nix::buildset::UnionRequest {
                cases: union_cases,
                work_dir: &build_dir,
                result_file: result_file.clone(),
                route: &route,
                // The build tail is a few long compiles; jobs default to
                // the machine's parallelism, with WASINIX_MAX_JOBS as the
                // override.
                max_jobs: crate::nix::route::max_jobs(
                    std::thread::available_parallelism()
                        .map(|jobs| jobs.get())
                        .unwrap_or(1),
                )?,
                hard_timeout,
                push: ctx.push_cache,
            },
            &mut |event| match event {
                crate::nix::buildset::StreamEvent::Result(value) => {
                    liveness.activity();
                    record_result(&value, &mut jobs, tracker)?;
                    realising.retain(|attr| jobs.get(attr).is_none_or(|job| job.status.is_none()));
                    Ok(())
                }
                crate::nix::buildset::StreamEvent::Plan(census) => {
                    plan.extend(census);
                    Ok(())
                }
                crate::nix::buildset::StreamEvent::Activity => {
                    liveness.activity();
                    Ok(())
                }
                crate::nix::buildset::StreamEvent::Heartbeat { recent_deps } => {
                    liveness.heartbeat(tracker, &realising, &recent_deps)
                }
                crate::nix::buildset::StreamEvent::AutomaticGc { requested_bytes } => tracker
                    .record(Event::AutomaticGc {
                        at: unix_secs(),
                        task_ids: group_task_ids.clone(),
                        requested_bytes: Bytes(requested_bytes),
                    }),
                crate::nix::buildset::StreamEvent::Output(line) => {
                    if let Some(attr) = scheduled_attr(&line) {
                        if jobs.contains_key(&attr) && realising.insert(attr.clone()) {
                            tracker.record(Event::JobStarted {
                                at: unix_secs(),
                                job: JobAddr(attr),
                            })?;
                        }
                    }
                    Ok(())
                }
            },
        )?;
        union_artifacts.record(&result_file)?;
        union_artifacts.record(&build_dir.join("build-results.jsonl"))?;
        union_artifacts.record_log(&build_dir.join("build-union.log"))?;
        // The per-job facts are the verdict; a failing driver status with
        // every selected job reporting success is a teardown anomaly worth
        // recording.
        if !status.is_success() {
            let error = crate::support::fs::read_to_string(&build_dir.join("build-union.log"))
                .map(|log| crate::ci::report::log_headline(&log))?;
            let affected_jobs: Vec<JobAddr> = jobs
                .iter()
                .filter(|(job, state)| {
                    case_ids
                        .iter()
                        .any(|case_id| job.starts_with(&format!("{case_id}::")))
                        && state.status != Some(JobStatus::Success)
                })
                .map(|(job, _)| JobAddr(job.clone()))
                .collect();
            tracker.record(Event::Diagnostic {
                at: unix_secs(),
                diagnostic: build_process_diagnostic(error.clone(), affected_jobs),
            })?;
            for case_id in case_ids {
                build_process_errors.insert(case_id, error.clone());
            }
        }
    }

    // What nix itself said failed, from the realise output. It names the
    // derivation, the reason and the tail of its log, which is the only
    // account a job blocked behind it can carry.
    let reported: Vec<crate::nix::buildset::BuilderFailure> = union_logs
        .iter()
        .filter_map(|path| std::fs::read_to_string(path).ok())
        .flat_map(|text| crate::nix::buildset::builder_failures(&text))
        .collect();
    let shared_bytes = union_artifacts.bytes();
    let task_count = specs.len() as u64;
    for (index, spec) in specs.into_iter().enumerate() {
        let mut artifacts = Artifacts::default();
        artifacts.add_shared(
            shared_bytes / task_count + u64::from((index as u64) < shared_bytes % task_count),
        )?;
        let paths = case_dir(ctx.run_dir, &spec.case);
        let junit =
            crate::ci::prepare::junit_dir(&paths).join(format!("{}.xml", spec.target.as_str()));
        let source = results
            .get(&spec.case)
            .ok_or_else(|| Error::Failure(format!("{}: no union results", spec.case)))?;
        project_junit(source, &junit, &spec.case, &spec.jobs, &jobs)?;
        artifacts.record(&junit)?;
        let mapping = maps.get(&spec.case).expect("spec map was loaded");
        let logs_dir = crate::ci::prepare::logs_dir(&paths).join(spec.target.as_str());
        let mut build_facts = facts::ingest(
            &[junit.clone()],
            Some(&crate::ci::prepare::eval_jobs_path(&paths)),
            &mapping.info,
            cutoff,
            &logs_dir,
            &reported,
        )?;
        let diagnostic = build_process_errors.get(&spec.case).map(|message| {
            let affected_jobs: Vec<JobAddr> = build_facts
                .failures
                .iter()
                .filter(|failure| {
                    failure.message.as_deref() == Some(crate::ci::facts::NO_BUILD_LOG)
                })
                .map(|failure| failure.job.clone())
                .collect();
            build_process_diagnostic(message.clone(), affected_jobs)
        });
        if build_facts.complete {
            artifacts.record(&logs_dir.join("manifest.json"))?;
        }
        for log in build_facts
            .failures
            .iter()
            .filter_map(|failure| failure.log.as_ref())
        {
            artifacts.record(&logs_dir.join(&log.path))?;
        }
        // The ingest classifies each failure: jobs that never ran because
        // something below them failed first are blocked, not failing, so a
        // task whose only losses are blocked carries that distinct outcome.
        let blocked = build_facts
            .failures
            .iter()
            .filter(|failure| failure.cause == facts::FailureCause::Transitive)
            .count();
        let unsuccessful = spec
            .jobs
            .iter()
            .filter(|name| {
                jobs.get(&format!("{}::{name}", spec.case))
                    .is_none_or(|job| job.status != Some(JobStatus::Success))
            })
            .count();
        let (failed, status) = classify_build_outcome(unsuccessful, blocked);
        // Where the selected jobs went. `reused` came from a published
        // baseline and never entered the build, so the dry run never saw
        // them; the rest is the plan's split minus what actually failed.
        let reused = spec
            .jobs
            .iter()
            .filter(|name| {
                jobs.get(&format!("{}::{name}", spec.case))
                    .is_some_and(|job| job.drv.is_empty())
            })
            .count();
        // This task's own share of the plan. The three sets build as one
        // union, so the union's totals are nobody's answer: reporting them
        // per task read as "1007 selected · 1266 built".
        let planned = |want: crate::nix::buildset::Planned| {
            spec.jobs
                .iter()
                .filter(|name| {
                    plan.get(&format!("{}::{name}", spec.case))
                        .is_some_and(|planned| *planned == want)
                })
                .count()
        };
        let to_build = planned(crate::nix::buildset::Planned::Build);
        build_facts.census = Some(facts::JobCensus {
            selected: spec.jobs.len(),
            reused,
            to_build,
            substitutable: planned(crate::nix::buildset::Planned::Substitutable),
            present: planned(crate::nix::buildset::Planned::Present),
            built: to_build.saturating_sub(failed + blocked),
            failed,
            blocked,
        });
        let headline =
            crate::support::ui::counts(&build_facts.census.as_ref().expect("just set").parts());
        let mut fragment = Fragment::new(
            spec.task_id.clone(),
            spec.label.clone(),
            spec.kind,
            status,
            headline,
        )
        .with_data(FragmentData::Build(build_facts));
        if let Some(diagnostic) = diagnostic {
            fragment = fragment.with_diagnostic(diagnostic);
        }
        worst = worst.max(
            finish_task(
                ctx,
                tracker,
                fragment,
                Some(TaskTelemetry::collect(union_started, &artifacts)),
            )?
            .exit(request.blocked),
        );
    }
    Ok(worst)
}

fn content(ctx: &Context, request: &ResolvedRequest, candidate_id: &str) -> Result<Fragment> {
    let RequestAction::Diff(diff) = &request.action else {
        return request_error("content requires a diff request");
    };
    if !diff.content_diff {
        return request_error("content requires a content-enabled diff request");
    }
    let candidate = diff
        .cases
        .iter()
        .find(|case| case.case_id() == candidate_id)
        .and_then(|case| case.as_build())
        .ok_or_else(|| Error::Request(format!("unknown candidate {candidate_id:?}")))?;
    let head_paths = case_dir(ctx.run_dir, candidate_id);
    let head_map = load_map(&head_paths)?;
    let base_map = load_map(&case_dir(ctx.run_dir, &diff.baseline))?;
    let mut junits: Vec<PathBuf> = std::fs::read_dir(crate::ci::prepare::junit_dir(&head_paths))
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "xml"))
                .collect()
        })
        .unwrap_or_default();
    junits.sort();
    let allowed = crate::ci::compare::selected(candidate, &head_map)?;
    let route = Route::from_on(ctx.runner_root, candidate.on.as_deref())?;
    let summary = crate::ci::contentdiff::run(&crate::ci::contentdiff::Request {
        base_map: &base_map,
        head_map: &head_map,
        junit: &junits,
        allowed_jobs: Some(&allowed),
        store: route.store().as_deref(),
    });
    // Skipped pairs were not compared; counting them in the denominator
    // would present "could not fetch a side" as "every output changed".
    let compared = summary.identical.len() + summary.changed.len();
    let headline = if summary.pair_count() == 0 {
        "nothing to compare".to_string()
    } else if compared == 0 {
        format!("{} pairs skipped, none compared", summary.skipped.len())
    } else if summary.skipped.is_empty() {
        format!("{}/{compared} outputs identical", summary.identical.len())
    } else {
        format!(
            "{}/{compared} outputs identical · {} skipped",
            summary.identical.len(),
            summary.skipped.len()
        )
    };
    Ok(Fragment::new(
        format!("content-diff.{candidate_id}"),
        format!("Content diff: {candidate_id}"),
        TaskKind::Analysis,
        TaskStatus::Success,
        headline,
    )
    .with_data(FragmentData::Content(summary)))
}

/// Run one planned task. The match is exhaustive: a new phase cannot be added
/// without deciding what runs it.
fn run_phase(
    ctx: &Context,
    request: &ResolvedRequest,
    case_id: &str,
    phase: Phase,
    artifacts: &mut Artifacts,
) -> Result<Fragment> {
    if phase == Phase::Content {
        return content(ctx, request, case_id);
    }

    let case = request
        .cases()
        .into_iter()
        .find(|case| case.case_id() == case_id)
        .ok_or_else(|| Error::Request(format!("unknown case {case_id:?}")))?;
    let route = task_route(ctx.runner_root, phase, case.placement())?;
    let patch = case_dir(ctx.run_dir, case_id)
        .join("prepared")
        .join(PATCH_FILE);
    let worktree = reproduced_worktree(ctx.runner_root, case.source(), &patch)?;
    match (phase, case) {
        (Phase::Repository, _) => {
            repository_checks(ctx, worktree.path(), case_id, &route, artifacts)
        }
        (Phase::EvalInputs, CaseRef::Build(build)) => {
            eval_inputs(ctx, worktree.path(), build, &route, artifacts)
        }
        (Phase::EvalInputs, CaseRef::Spot(_)) => request_error("eval-inputs phase on a spot case"),
        (Phase::Eval, CaseRef::Build(build)) => {
            evaluate(ctx, worktree.path(), build, &route, artifacts)
        }
        (Phase::Spot, CaseRef::Spot(spot_case)) => {
            spot(ctx, worktree.path(), case_id, spot_case, &route, artifacts)
        }
        (Phase::Spot, CaseRef::Build(_)) => request_error("spot phase on a build case"),
        (Phase::Build { .. }, CaseRef::Build(_)) => {
            request_error("build phases are executed as one union")
        }
        (Phase::Eval | Phase::Build { .. }, CaseRef::Spot(_)) => {
            request_error("build phase on a spot case")
        }
        (Phase::Content, _) => unreachable!("handled above"),
    }
}

pub(crate) fn task_route(repo: &Path, phase: Phase, placement: Option<&str>) -> Result<Route> {
    match phase {
        Phase::Repository => Route::local(),
        _ => Route::from_on(repo, placement),
    }
}

/// A phase whose failure leaves no valid jobs to build or compare. Builds run
/// as one union, so there is no core-before-packages ordering to poison.
pub(crate) fn fatal(phase: Phase) -> bool {
    matches!(phase, Phase::Repository | Phase::EvalInputs | Phase::Eval)
}

pub(crate) fn classify_build_outcome(unsuccessful: usize, blocked: usize) -> (usize, TaskStatus) {
    assert!(
        blocked <= unsuccessful,
        "blocked jobs cannot exceed unsuccessful jobs"
    );
    let failed = unsuccessful - blocked;
    let status = if failed > 0 {
        TaskStatus::Failure
    } else if blocked > 0 {
        TaskStatus::Blocked
    } else {
        TaskStatus::Success
    };
    (failed, status)
}

/// The one place a task ends: the fragment is written and its PhaseFinished
/// emitted together, so no task can leave a result the ladder never closes
/// or a closed phase with no result on disk.
fn finish_task(
    ctx: &Context,
    tracker: &mut Tracker,
    mut fragment: Fragment,
    telemetry: Option<TaskTelemetry>,
) -> Result<TaskStatus> {
    if let Some(telemetry) = telemetry {
        fragment.elapsed_seconds = Some(DurationSecs(telemetry.elapsed.as_secs_f64()));
        fragment.artifact_bytes = Some(Bytes(telemetry.artifact_bytes));
    }
    record_resource_sample(
        tracker,
        &fragment.task_id,
        crate::ci::events::ResourceBoundary::Finish,
    )?;
    fragment.write(&ctx.fragment_path(&fragment.task_id))?;
    tracker.record(Event::PhaseFinished {
        at: unix_secs(),
        task_id: fragment.task_id.clone(),
        status: fragment.status,
        headline: fragment.headline.clone(),
    })?;
    Ok(fragment.status)
}

fn start_task(
    tracker: &mut Tracker,
    task_id: &str,
    label: &str,
    jobs: Option<usize>,
) -> Result<()> {
    tracker.record(Event::PhaseStarted {
        at: unix_secs(),
        task_id: task_id.to_string(),
        label: label.to_string(),
        jobs,
    })?;
    record_resource_sample(tracker, task_id, crate::ci::events::ResourceBoundary::Start)
}

struct TaskTelemetry {
    elapsed: Duration,
    artifact_bytes: u64,
}

impl TaskTelemetry {
    fn collect(started: Instant, artifacts: &Artifacts) -> TaskTelemetry {
        TaskTelemetry {
            elapsed: started.elapsed(),
            artifact_bytes: artifacts.bytes(),
        }
    }
}

fn record_resource_sample(
    tracker: &mut Tracker,
    task_id: &str,
    boundary: crate::ci::events::ResourceBoundary,
) -> Result<()> {
    let space = crate::support::fs::space(Path::new("/nix/store"))?;
    tracker.record(Event::ResourceSample {
        at: unix_secs(),
        task_id: task_id.to_string(),
        boundary,
        available_bytes: Bytes(space.available),
        total_bytes: Bytes(space.total),
    })
}

/// Walk the plan in this process. `only` names the tasks to run, in plan
/// order; empty means all of them, which is the only case that also folds the
/// run's report.
pub fn run_tasks(ctx: &Context, loaded: &Loaded, only: &[String]) -> Result<CommandStatus> {
    let request = &loaded.request;
    let plan = loaded.plan();
    crate::support::fs::create_dir_all(&ctx.fragments())?;
    let unknown: Vec<&String> = only
        .iter()
        .filter(|id| !plan.tasks.iter().any(|task| &task.task_id == *id))
        .collect();
    if !unknown.is_empty() {
        let named: Vec<&str> = unknown.iter().map(|id| id.as_str()).collect();
        let known: Vec<&str> = plan
            .tasks
            .iter()
            .map(|task| task.task_id.as_str())
            .collect();
        return request_error(format!(
            "unknown task(s) {}; this run plans {}",
            named.join(", "),
            known.join(", ")
        ));
    }
    let mut tasks: Vec<Task> = plan
        .tasks
        .iter()
        .filter(|task| only.is_empty() || only.contains(&task.task_id))
        .cloned()
        .collect();
    tasks.sort_by_key(|task| task.order);

    let mut tracker = Tracker::new(ctx.run_dir)?;

    let mut broken: Vec<String> = Vec::new();
    let mut worst = CommandStatus::SUCCESS;
    let mut builds_ran = false;
    for task in &tasks {
        if matches!(task.phase, Phase::Build { .. }) {
            if builds_ran {
                continue;
            }
            builds_ran = true;
            let status = match run_build_tasks(ctx, request, &tasks, &broken, &mut tracker) {
                Ok(status) => status,
                Err(error) => {
                    let detail = error.to_string();
                    // Every planned build task still ends through the gate,
                    // so none is left with a started phase that never
                    // finishes.
                    for build in tasks
                        .iter()
                        .filter(|task| matches!(task.phase, Phase::Build { .. }))
                    {
                        if !ctx.fragment_path(&build.task_id).exists() {
                            finish_task(
                                ctx,
                                &mut tracker,
                                crate::ci::report::union_failure_fragment(
                                    build.task_id.clone(),
                                    build.label.clone(),
                                    build.kind,
                                    &detail,
                                ),
                                None,
                            )?;
                        }
                    }
                    CommandStatus::FAILURE
                }
            };
            worst = worst.max(status);
            continue;
        }
        if broken.contains(&task.case) {
            start_task(&mut tracker, &task.task_id, &task.label, None)?;
            finish_task(
                ctx,
                &mut tracker,
                Fragment::new(
                    task.task_id.clone(),
                    task.label.clone(),
                    task.kind,
                    TaskStatus::Skipped,
                    "an earlier task in this case failed",
                ),
                None,
            )?;
            continue;
        }
        // A content diff against a baseline that never evaluated has no base
        // side to read; it stays unreported rather than failing as advisory
        // noise for the base's condition.
        if task.phase == Phase::Content
            && loaded
                .baseline_case()
                .is_some_and(|baseline| broken.contains(&baseline))
        {
            continue;
        }
        start_task(&mut tracker, &task.task_id, &task.label, None)?;
        let started = Instant::now();
        let mut artifacts = Artifacts::default();
        let fragment = match run_phase(ctx, request, &task.case, task.phase, &mut artifacts) {
            Ok(fragment) => fragment,
            Err(error) => Fragment::new(
                task.task_id.clone(),
                task.label.clone(),
                task.kind,
                TaskStatus::Failure,
                crate::support::error::brief(&error, 200),
            ),
        };
        let status = finish_task(
            ctx,
            &mut tracker,
            fragment,
            Some(TaskTelemetry::collect(started, &artifacts)),
        )?;
        let task_status = status.exit(request.blocked);
        worst = worst.max(task_status);
        if !task_status.is_success() && fatal(task.phase) {
            broken.push(task.case.clone());
        }
    }

    if !only.is_empty() {
        // A single task reports through its fragment; the report describes
        // the whole run, and folding it here would describe one in progress.
        let status = if worst.is_success() {
            CommandStatus::SUCCESS
        } else {
            CommandStatus::FAILURE
        };
        return Ok(status);
    }

    let fragments = crate::ci::report::fragments_under(&ctx.fragments())?;
    let mut report = crate::ci::report::fold(
        &plan,
        &fragments,
        crate::ci::report::FoldContext {
            baseline_case: loaded.baseline_case(),
            finished: true,
            started_at: tracker.snapshot().started_at,
            finished_at: Some(unix_secs()),
            request: Some(request.clone()),
            reused_cases: loaded.preparation.reused.len(),
            comparisons: crate::ci::compare::project(ctx.run_dir, request, true)?,
        },
    );
    report.attach_run_data(ctx.run_dir)?;
    schema::write(&crate::ci::prepare::report_path(ctx.run_dir), &report)?;
    let status = report.command_status();
    Ok(status)
}
