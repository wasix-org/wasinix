//! Build selected CI jobs. Wasinix records the plan and reports outcomes;
//! nix-fast-build evaluates the selected attributes and schedules builds.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::mpsc;
use std::time::Duration;

use serde_json::Value;

use crate::support::error::{Error, Result, io, request_error};
use crate::support::process::CommandStatus;

pub struct UnionCase {
    pub id: String,
    pub worktree: PathBuf,
    pub jobs_file: PathBuf,
    pub jobs: Vec<String>,
}

pub struct UnionRequest<'a> {
    pub cases: Vec<UnionCase>,
    pub work_dir: &'a Path,
    pub result_file: PathBuf,
    pub route: &'a crate::nix::route::Route,
    pub max_jobs: usize,
    pub hard_timeout: Option<Duration>,
    /// Whether to sign and push; the signing key still has to be present.
    pub push: bool,
}

/// What the dry run expects to do with one job address. Several addresses
/// share one derivation, so this is per address, not the derivation count
/// the uploader works in.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Planned {
    Build,
    Fetch,
    Present,
}

/// The dry run's prediction, per job address. Keyed rather than counted:
/// several tasks share one union, and a count could only be the union's,
/// which is not any one task's answer.
pub type PlanCensus = BTreeMap<String, Planned>;

pub enum StreamEvent {
    Result(Value),
    /// What the build expects to do, before it does any of it.
    Plan(PlanCensus),
    Activity,
    /// The most recently announced dependency builds, so the ticker can say
    /// what the run is doing when no job derivation is in flight.
    Heartbeat {
        recent_deps: Vec<String>,
    },
    AutomaticGc {
        requested_bytes: u64,
    },
    Output(String),
}

/// The key, written where nix can read it. A key that is not ours would sign
/// artifacts the cache then serves, so it is checked before it is used.
struct SigningKey {
    path: PathBuf,
}

impl SigningKey {
    fn take() -> Result<Option<SigningKey>> {
        let Some(secret) = crate::support::env::signing_key()? else {
            crate::support::ui::fact("cache upload", "off (no signing key)");
            return Ok(None);
        };
        let path =
            crate::support::env::temp_dir().join(format!("wasinix-key-{}", std::process::id()));
        // Private from the first byte: the file never exists world-readable,
        // and a leftover path (or a planted symlink) fails the create.
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        let mut file = options.open(&path).map_err(|e| io(&path, e))?;
        file.write_all(format!("{}\n", secret.trim_end()).as_bytes())
            .map_err(|e| io(&path, e))?;
        drop(file);
        let key = SigningKey { path };
        let public = crate::support::nix::Invocation::plain("key convert-secret-to-public")
            .stdin(&key.path)
            .checked_text("verifying the signing key")?;
        if public.trim() != crate::support::nix::CACHE_PUBLIC_KEY {
            return request_error(format!(
                "NIX_SIGNING_KEY does not match the cache key ({})",
                public.trim()
            ));
        }
        crate::support::ui::fact("cache upload", "on");
        Ok(Some(key))
    }

    fn store(&self) -> String {
        format!(
            "{}&secret-key={}",
            crate::support::nix::cache_push_store(),
            self.path.display()
        )
    }
}

impl Drop for SigningKey {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.path) {
            crate::support::ui::warning(format!(
                "could not remove the signing key at {}: {error}",
                self.path.display()
            ));
        }
    }
}

fn needed_builds_for(path: &Path, wanted: &[String]) -> Result<BTreeSet<String>> {
    let text = crate::support::fs::read_to_string(path)?;
    let mut needed = BTreeSet::new();
    for job in crate::nix::evaljobs::parse_file(&text)? {
        if wanted.contains(&job.name()) {
            needed.extend(job.needed_builds);
        }
    }
    Ok(needed)
}

/// Realise and push build-time dependencies an output push would miss. The
/// streamed pushes cover what built this run; this end-of-run pass is the
/// completeness backstop for everything else the jobs need. `--keep-going`
/// so one broken dependency does not block the rest; push failures warn
/// rather than fail: the cache is an accelerator, not a build product.
fn push_build_deps(
    key: &SigningKey,
    drvs: &BTreeSet<String>,
    route: &crate::nix::route::Route,
) -> Result<()> {
    if drvs.is_empty() {
        return Ok(());
    }
    let realised = crate::support::nix::Invocation::tool("nix-store")
        .args(["--realise", "--keep-going"])
        .operands(drvs.iter().cloned())
        .probe("keep-going: push whatever realised")?;
    let outputs: Vec<String> = String::from_utf8_lossy(&realised.stdout)
        .split_whitespace()
        .map(str::to_string)
        .collect();
    if outputs.is_empty() {
        return Ok(());
    }
    crate::support::ui::fact("pushing build-time paths", outputs.len());
    let mut copy = crate::support::nix::Invocation::plain("copy");
    if let Some(store) = route.store() {
        copy = copy.args(["--from", &store]);
    }
    let (copied, detail) = copy
        .args(["--to", &key.store()])
        .operands(outputs)
        .captured_status()?;
    if !copied.is_success() {
        crate::support::ui::warning(format!("build-dep push failed (non-fatal): {detail}"));
    }
    Ok(())
}

/// One selected derivation: which attrs share it (a union may select the
/// same derivation under several names) and its output paths.
struct JobSpec {
    attrs: Vec<String>,
    outputs: Vec<String>,
}

/// A dry-run plan, partitioned: the derivations that must actually build,
/// and the paths that would be fetched from a substituter. A path in neither
/// set is already valid locally.
pub(crate) struct DryRunPlan {
    pub(crate) to_build: BTreeSet<String>,
    pub(crate) fetched: BTreeSet<String>,
}

/// Parse `nix-store --realise --dry-run` output. Everything outside the
/// build section is either substitutable or already valid locally, which the
/// driver reports as cached without realising, so a warm run downloads
/// nothing.
pub(crate) fn dry_run_plan(plan: &str) -> Result<DryRunPlan> {
    let mut to_build = BTreeSet::new();
    let mut fetched = BTreeSet::new();
    let mut in_build_section = false;
    let mut in_fetch_section = false;
    let mut recognized = false;
    for line in plan.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("this derivation will be built")
            || (trimmed.starts_with("these ") && trimmed.contains("will be built"))
        {
            in_build_section = true;
            in_fetch_section = false;
            recognized = true;
            continue;
        }
        if trimmed.starts_with("this path will be fetched")
            || (trimmed.starts_with("these ") && trimmed.contains("will be fetched"))
        {
            in_build_section = false;
            in_fetch_section = true;
            recognized = true;
            continue;
        }
        if trimmed.starts_with("/nix/store/") {
            if in_build_section && trimmed.ends_with(".drv") {
                to_build.insert(trimmed.to_string());
            }
            if in_fetch_section {
                fetched.insert(trimmed.to_string());
            }
            continue;
        }
        in_build_section = false;
        in_fetch_section = false;
    }
    // A phrasing this parser does not know must not read as "fully cached".
    if !recognized && plan.contains(".drv") {
        return Err(crate::support::error::Error::Failure(format!(
            "unrecognized dry-run plan phrasing:\n{}",
            crate::support::error::tail(plan, 500)
        )));
    }
    Ok(DryRunPlan { to_build, fetched })
}

/// A derivation whose builder failed, as nix reported it. The realise
/// output carries the name, the reason and the tail of the build log, which
/// is the whole explanation for every job that never ran behind it.
#[derive(Debug, Clone, PartialEq)]
pub struct BuilderFailure {
    pub drv: String,
    pub reason: String,
    pub log: Vec<String>,
}

/// Parse the builder failures out of a realise log. Blocks whose reason is a
/// failed dependency are victims of another block, not causes, and are left
/// to whatever failed under them.
pub fn builder_failures(output: &str) -> Vec<BuilderFailure> {
    let mut found: Vec<BuilderFailure> = Vec::new();
    let mut lines = output.lines().peekable();
    while let Some(line) = lines.next() {
        let Some(drv) = line
            .strip_prefix("error: Cannot build '")
            .and_then(|rest| rest.split_once('\'').map(|(drv, _)| drv))
        else {
            continue;
        };
        let Some(reason) = lines
            .peek()
            .and_then(|next| next.trim().strip_prefix("Reason: "))
            .map(|reason| reason.trim_end_matches('.').to_string())
        else {
            continue;
        };
        if reason.contains("dependency failed") {
            continue;
        }
        let mut log = Vec::new();
        let mut in_log = false;
        for line in lines.by_ref() {
            let trimmed = line.trim();
            if trimmed.starts_with("Last ") && trimmed.ends_with("log lines:") {
                in_log = true;
                continue;
            }
            match trimmed.strip_prefix("> ") {
                Some(text) if in_log => log.push(text.to_string()),
                _ if in_log => break,
                _ if trimmed.starts_with("error: ") => break,
                _ => {}
            }
        }
        if !found.iter().any(|seen| seen.drv == drv) {
            found.push(BuilderFailure {
                drv: drv.to_string(),
                reason,
                log,
            });
        }
    }
    found
}

/// Batches finished outputs to the signed push store from its own thread, so
/// uploads overlap builds and a cancel keeps everything already copied.
struct Uploader {
    sender: Option<mpsc::Sender<Vec<String>>>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl Uploader {
    fn start(store: Option<String>, from: Option<String>) -> Uploader {
        let Some(store) = store else {
            return Uploader {
                sender: None,
                handle: None,
            };
        };
        let (sender, receiver) = mpsc::channel::<Vec<String>>();
        let handle = std::thread::spawn(move || {
            let mut batch: Vec<String> = Vec::new();
            loop {
                match receiver.recv_timeout(Duration::from_secs(5)) {
                    Ok(paths) => {
                        batch.extend(paths);
                        if batch.len() < 32 {
                            continue;
                        }
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => {
                        Self::flush(&store, from.as_deref(), &mut batch);
                        return;
                    }
                }
                Self::flush(&store, from.as_deref(), &mut batch);
            }
        });
        Uploader {
            sender: Some(sender),
            handle: Some(handle),
        }
    }

    fn flush(store: &str, from: Option<&str>, batch: &mut Vec<String>) {
        if batch.is_empty() {
            return;
        }
        let mut copy = crate::support::nix::Invocation::plain("copy");
        if let Some(from) = from {
            copy = copy.args(["--from", from]);
        }
        match copy
            .args(["--to", store])
            .operands(batch.drain(..))
            .captured_status()
        {
            Ok((status, _)) if status.is_success() => {}
            Ok((_, detail)) => {
                crate::support::ui::warning(format!("cache push failed (non-fatal): {detail}"))
            }
            Err(error) => {
                crate::support::ui::warning(format!("cache push failed (non-fatal): {error}"))
            }
        }
    }

    fn push(&self, paths: Vec<String>) {
        if let Some(sender) = &self.sender {
            let _ = sender.send(paths);
        }
    }

    fn finish(mut self) {
        self.close_and_join();
    }

    fn close_and_join(&mut self) {
        drop(self.sender.take());
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

impl Drop for Uploader {
    fn drop(&mut self) {
        self.close_and_join();
    }
}

pub struct PrebuiltPush {
    pub push: Vec<String>,
    pub candidates: usize,
    pub in_cache: usize,
    pub unbuilt: usize,
}

/// Partition evaluated job outputs for a retroactive push: drvs the dry-run
/// would build are not built here, outputs it would fetch are in the cache
/// already, and the rest is locally valid and never pushed.
pub(crate) fn prebuilt_partition(
    outputs_by_drv: &BTreeMap<String, Vec<String>>,
    plan: &DryRunPlan,
) -> PrebuiltPush {
    let mut report = PrebuiltPush {
        push: Vec::new(),
        candidates: 0,
        in_cache: 0,
        unbuilt: 0,
    };
    for (drv, outputs) in outputs_by_drv {
        if plan.to_build.contains(drv) {
            report.unbuilt += 1;
            continue;
        }
        let local: Vec<String> = outputs
            .iter()
            .filter(|output| !plan.fetched.contains(*output))
            .cloned()
            .collect();
        if local.is_empty() {
            report.in_cache += 1;
            continue;
        }
        report.candidates += 1;
        report.push.extend(local);
    }
    report
}

/// Push everything already built for these jobs that the cache lacks.
/// `nix copy` skips paths the cache turns out to hold, so the candidate
/// count is an upper bound on what actually transfers.
pub fn push_prebuilt(
    outputs_by_drv: &BTreeMap<String, Vec<String>>,
    route: &crate::nix::route::Route,
) -> Result<PrebuiltPush> {
    let Some(key) = SigningKey::take()? else {
        return request_error("pushing to the cache needs NIX_SIGNING_KEY");
    };
    let plan = crate::support::nix::Invocation::tool("nix-store")
        .args(["--realise", "--dry-run"])
        .operands(outputs_by_drv.keys().cloned())
        .route(route)?
        .probe("the dry-run plan partitions cached from to-build")?;
    let plan = dry_run_plan(&plan.stderr)?;
    let report = prebuilt_partition(outputs_by_drv, &plan);
    let uploader = Uploader::start(Some(key.store()), route.store());
    uploader.push(report.push.clone());
    uploader.finish();
    Ok(report)
}

pub(crate) fn select_jobs(jobs: &[String]) -> Result<String> {
    let names = jobs
        .iter()
        .map(serde_json::to_string)
        .collect::<std::result::Result<Vec<_>, _>>()
        .map_err(|source| Error::Failure(format!("encoding build selectors: {source}")))?
        .join(" ");
    Ok(format!(
        "jobs: builtins.listToAttrs (map (name: {{ inherit name; value = builtins.getAttr name jobs; }}) [ {names} ])"
    ))
}

fn emit(
    value: Value,
    stream: &mut std::fs::File,
    stream_path: &Path,
    cases: &mut Vec<crate::ci::facts::junit::Case>,
    on_event: &mut dyn FnMut(StreamEvent) -> Result<()>,
) -> Result<()> {
    writeln!(stream, "{value}").map_err(|error| io(stream_path, error))?;
    let mut case = crate::ci::facts::junit::Case::new(
        value["attr"].as_str().unwrap_or_default().to_string(),
        "Build".to_string(),
    );
    case.duration = value["duration"].as_f64().unwrap_or_default();
    case.drv = value["drv"].as_str().map(str::to_string);
    if !value["success"].as_bool().unwrap_or(false) {
        case.message = Some(
            value["error"]
                .as_str()
                .unwrap_or("build failed")
                .to_string(),
        );
    }
    cases.push(case);
    on_event(StreamEvent::Result(value))
}

/// Build each selected case with nix-fast-build. Wasinix owns selection,
/// routing, reporting, and cache credentials; nix-fast-build owns evaluation,
/// retries, and the per-derivation build schedule.
pub fn build_union(
    request: UnionRequest<'_>,
    on_event: &mut dyn FnMut(StreamEvent) -> Result<()>,
) -> Result<CommandStatus> {
    crate::support::fs::create_dir_all(request.work_dir)?;
    if let Some(parent) = request.result_file.parent() {
        crate::support::fs::create_dir_all(parent)?;
    }
    let work_dir =
        std::path::absolute(request.work_dir).map_err(|error| io(request.work_dir, error))?;
    let log_path = work_dir.join("build-union.log");
    let stream_path = work_dir.join("build-results.jsonl");
    let mut log = crate::support::log::BoundedLog::create(&log_path)?;
    let mut stream = std::fs::File::create(&stream_path).map_err(|e| io(&stream_path, e))?;

    let mut jobs: BTreeMap<String, JobSpec> = BTreeMap::new();
    let mut attrs: BTreeMap<String, String> = BTreeMap::new();
    let mut missing: Vec<String> = Vec::new();
    for case in &request.cases {
        let text = crate::support::fs::read_to_string(&case.jobs_file)?;
        let selected: BTreeSet<&str> = case.jobs.iter().map(String::as_str).collect();
        for job in crate::nix::evaljobs::parse_file(&text)? {
            let name = job.name();
            if !selected.contains(name.as_str()) {
                continue;
            }
            let attr = format!("{}::{name}", case.id);
            match job.drv_path.clone().filter(|drv| !drv.is_empty()) {
                Some(drv) => {
                    attrs.insert(attr.clone(), drv.clone());
                    let spec = jobs.entry(drv).or_insert_with(|| JobSpec {
                        attrs: Vec::new(),
                        outputs: job.outputs.values().cloned().collect(),
                    });
                    spec.attrs.push(attr);
                }
                None => missing.push(attr),
            }
        }
    }

    let mut cases: Vec<crate::ci::facts::junit::Case> = Vec::new();
    let mut failures = 0usize;
    for attr in &missing {
        failures += 1;
        emit(
            serde_json::json!({
                "type": "BUILD", "attr": attr, "success": false,
                "error": "the evaluation produced no derivation for this job",
            }),
            &mut stream,
            &stream_path,
            &mut cases,
            on_event,
        )?;
    }

    let key = if request.push {
        SigningKey::take()?
    } else {
        None
    };
    let mut needed = BTreeSet::new();
    if key.is_some() {
        for case in &request.cases {
            needed.extend(needed_builds_for(&case.jobs_file, &case.jobs)?);
        }
    }

    // Partition: what must build versus what the caches already carry.
    let plan = crate::support::nix::Invocation::tool("nix-store")
        .args(["--realise", "--dry-run"])
        .operands(jobs.keys().cloned())
        .route(request.route)?
        .probe("the dry-run plan partitions cached from to-build")?;
    let plan = dry_run_plan(&plan.stderr)?;
    let to_build = plan.to_build;

    let mut pending: BTreeSet<String> = BTreeSet::new();
    let mut local_only: Vec<String> = Vec::new();
    let mut census = PlanCensus::new();
    for (drv, spec) in &jobs {
        let planned = if to_build.contains(drv) {
            Planned::Build
        } else if spec
            .outputs
            .iter()
            .any(|output| plan.fetched.contains(output))
        {
            Planned::Fetch
        } else {
            Planned::Present
        };
        for attr in &spec.attrs {
            census.insert(attr.clone(), planned);
        }
        if planned == Planned::Build {
            pending.extend(spec.attrs.iter().cloned());
            continue;
        }
        local_only.extend(
            spec.outputs
                .iter()
                .filter(|output| !plan.fetched.contains(*output))
                .cloned(),
        );
        for attr in &spec.attrs {
            emit(
                serde_json::json!({
                    "type": "BUILD", "attr": attr, "drv": drv, "success": true,
                    "cached": true, "duration": 0.0,
                }),
                &mut stream,
                &stream_path,
                &mut cases,
                on_event,
            )?;
        }
    }
    let count = |want: Planned| census.values().filter(|planned| **planned == want).count();
    crate::support::ui::fact(
        "build plan",
        format!(
            "{} to build · {} to fetch · {} present",
            count(Planned::Build),
            count(Planned::Fetch),
            count(Planned::Present)
        ),
    );
    on_event(StreamEvent::Plan(census))?;

    let uploader = Uploader::start(key.as_ref().map(SigningKey::store), request.route.store());
    if key.is_some() && !local_only.is_empty() {
        crate::support::ui::fact("pushing locally built outputs", local_only.len());
        uploader.push(local_only);
    }
    let started = std::time::Instant::now();
    let mut timed_out = false;
    let mut driver_failed = false;
    for case in &request.cases {
        if timed_out {
            break;
        }
        let selected: Vec<String> = case
            .jobs
            .iter()
            .filter(|name| pending.contains(&format!("{}::{name}", case.id)))
            .cloned()
            .collect();
        if selected.is_empty() {
            continue;
        }
        let limits = request.route.limits()?;
        let flake = format!(
            ".#legacyPackages.{}.ciSets.all",
            crate::support::nix::SYSTEM
        );
        let invocation = crate::support::nix::Invocation::fast_build()
            .args(["--flake", &flake])
            .args(["--select", &select_jobs(&selected)?])
            .args(["--max-jobs", &request.max_jobs.to_string()])
            .args(["--eval-workers", &limits.workers.to_string()])
            .args(["--eval-max-memory-size", &limits.memory.to_string()])
            .args(["--retries", "3", "--no-nom", "--no-link", "--skip-cached"])
            .arg("--stream-json-lines")
            .accepts_flake_config()
            .workdir(&case.worktree)
            .route(request.route)?;
        let mut cmd = invocation.command()?;
        let mut child =
            crate::support::tools::spawn(cmd.stdout(Stdio::piped()).stderr(Stdio::piped()))?;
        let stdout = child.take_stdout().expect("stdout was piped");
        let stderr = child.take_stderr().expect("stderr was piped");
        let (sender, receiver) = mpsc::channel();
        let stdout_sender = sender.clone();
        let stdout_thread = std::thread::spawn(move || {
            let mut reader = BufReader::new(stdout);
            let mut buffer = Vec::new();
            while matches!(reader.read_until(b'\n', &mut buffer), Ok(n) if n > 0) {
                let line = String::from_utf8_lossy(&buffer).trim_end().to_string();
                let _ = stdout_sender.send((true, line));
                buffer.clear();
            }
        });
        let stderr_thread = std::thread::spawn(move || {
            let mut reader = BufReader::new(stderr);
            let mut buffer = Vec::new();
            while matches!(reader.read_until(b'\n', &mut buffer), Ok(n) if n > 0) {
                let line = String::from_utf8_lossy(&buffer).trim_end().to_string();
                let _ = sender.send((false, line));
                buffer.clear();
            }
        });
        let mut status = None;
        loop {
            match receiver.recv_timeout(Duration::from_secs(5)) {
                Ok((is_stdout, line)) => {
                    writeln!(log, "{line}").map_err(|e| io(&log_path, e))?;
                    if !is_stdout {
                        if let Some(requested_bytes) =
                            crate::support::nix::auto_gc_requested_bytes(&line)
                        {
                            on_event(StreamEvent::AutomaticGc { requested_bytes })?;
                        }
                    }
                    if is_stdout {
                        let value: Value =
                            serde_json::from_str(&line).map_err(|source| Error::Json {
                                path: "<nix-fast-build stdout>".into(),
                                source,
                            })?;
                        if let Some(name) = value["attr"].as_str() {
                            let attr = format!("{}::{name}", case.id);
                            if value["type"] == "BUILD" {
                                if let Some(drv) = attrs.get(&attr) {
                                    if value["success"].as_bool().unwrap_or(false) {
                                        let outputs = value["outputs"]
                                            .as_object()
                                            .into_iter()
                                            .flat_map(|outputs| outputs.values())
                                            .filter_map(Value::as_str)
                                            .map(str::to_string)
                                            .collect();
                                        uploader.push(outputs);
                                    }
                                    for alias in &jobs[drv].attrs {
                                        if !pending.remove(alias) {
                                            continue;
                                        }
                                        let mut normalized = value.clone();
                                        normalized["attr"] = Value::String(alias.clone());
                                        normalized["drv"] = Value::String(drv.clone());
                                        if !normalized["success"].as_bool().unwrap_or(false) {
                                            failures += 1;
                                        }
                                        emit(
                                            normalized,
                                            &mut stream,
                                            &stream_path,
                                            &mut cases,
                                            on_event,
                                        )?;
                                    }
                                }
                            } else if value["type"] == "EVAL"
                                && !value["success"].as_bool().unwrap_or(false)
                                && pending.remove(&attr)
                            {
                                failures += 1;
                                let mut normalized = value;
                                normalized["attr"] = Value::String(attr);
                                emit(normalized, &mut stream, &stream_path, &mut cases, on_event)?;
                            }
                        }
                    } else if let Some(name) = line.strip_prefix("  building ") {
                        let attr = format!("{}::{}", case.id, name.trim_matches('"'));
                        if attrs.contains_key(&attr) {
                            on_event(StreamEvent::Output(format!("  building \"{attr}\"")))?;
                        }
                    } else {
                        on_event(StreamEvent::Output(line))?;
                    }
                    on_event(StreamEvent::Activity)?;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
            on_event(StreamEvent::Heartbeat {
                recent_deps: Vec::new(),
            })?;
            if request
                .hard_timeout
                .is_some_and(|timeout| started.elapsed() >= timeout)
            {
                timed_out = true;
                child.kill().map_err(|error| io(&log_path, error))?;
                break;
            }
            if status.is_none() {
                status = child.try_wait().map_err(|error| io(&log_path, error))?;
            }
        }
        let _ = stdout_thread.join();
        let _ = stderr_thread.join();
        let status = match status {
            Some(status) => status,
            None => child.wait().map_err(|error| io(&log_path, error))?,
        };
        driver_failed |= !status.success();
    }

    for attr in std::mem::take(&mut pending) {
        let error = if timed_out {
            "the build timed out before this job finished".to_string()
        } else {
            crate::ci::facts::NO_BUILD_LOG.to_string()
        };
        failures += 1;
        emit(
            serde_json::json!({
                "type": "BUILD", "attr": attr, "drv": attrs.get(&attr),
                "success": false, "error": error,
            }),
            &mut stream,
            &stream_path,
            &mut cases,
            on_event,
        )?;
    }

    uploader.finish();
    cases.sort_by(|a, b| a.attr.cmp(&b.attr));
    crate::support::fs::write(
        &request.result_file,
        crate::ci::facts::junit::write_junit(&cases).as_bytes(),
    )?;
    if let Some(key) = &key {
        push_build_deps(key, &needed, request.route)?;
    }
    log.finish()?;
    Ok(if failures == 0 && !driver_failed {
        CommandStatus::SUCCESS
    } else {
        CommandStatus::FAILURE
    })
}
