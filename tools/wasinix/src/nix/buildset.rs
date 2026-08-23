//! Build selected CI jobs from the derivations the evaluation already
//! instantiated: no re-evaluation, ever. A dry-run partitions the jobs into
//! cached and to-build, one realise per attempt builds the rest, and
//! finished outputs stream to the cache as they complete, so a timeout or
//! cancel never loses built work.

use std::collections::{BTreeMap, BTreeSet};
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::mpsc;
use std::time::Duration;

use serde_json::Value;

use crate::support::error::{Result, io, request_error};
use crate::support::process::CommandStatus;

pub struct UnionCase {
    pub id: String,
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

/// One derivation's output paths, for tracking a build-time dependency to
/// completion.
fn drv_outputs(drv: &str) -> Result<Vec<String>> {
    let probe = crate::support::nix::Invocation::tool("nix-store")
        .args(["--query", "--outputs"])
        .operand(drv)
        .probe("a dependency with unqueryable outputs is not tracked")?;
    Ok(String::from_utf8_lossy(&probe.stdout)
        .split_whitespace()
        .map(str::to_string)
        .collect())
}

/// Push the tracked build-time dependencies whose outputs became valid, so a
/// cancel or timeout keeps the dependency builds already done.
fn settle_deps(dep_pending: &mut BTreeMap<String, Vec<String>>, uploader: &Uploader) -> Result<()> {
    if dep_pending.is_empty() {
        return Ok(());
    }
    let outputs: Vec<String> = dep_pending.values().flatten().cloned().collect();
    let invalid = invalid_outputs(&outputs)?;
    let finished: Vec<String> = dep_pending
        .iter()
        .filter(|(_, outputs)| outputs.iter().all(|out| !invalid.contains(out)))
        .map(|(drv, _)| drv.clone())
        .collect();
    for drv in finished {
        if let Some(outputs) = dep_pending.remove(&drv) {
            uploader.push(outputs);
        }
    }
    Ok(())
}

/// Realise and push build-time dependencies an output push would miss. The
/// streamed pushes cover what built this run; this end-of-run pass is the
/// completeness backstop for everything else the jobs need. `--keep-going`
/// so one broken dependency does not block the rest; push failures warn
/// rather than fail: the cache is an accelerator, not a build product.
fn push_build_deps(key: &SigningKey, drvs: &BTreeSet<String>) -> Result<()> {
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
    let (copied, detail) = crate::support::nix::Invocation::plain("copy")
        .args(["--to", &key.store()])
        .operands(outputs)
        .captured_status()?;
    if !copied.is_success() {
        crate::support::ui::warning(format!("build-dep push failed (non-fatal): {detail}"));
    }
    Ok(())
}

#[cfg(unix)]
fn kill_group(child: &crate::support::tools::Child) -> std::io::Result<()> {
    crate::support::process::signal_group(child.id(), libc::SIGTERM)
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

/// The derivation a realise progress line announces, e.g.
/// `building '/nix/store/xxx-foo.drv'...`.
pub(crate) fn realise_building_drv(line: &str) -> Option<&str> {
    let rest = line.trim_start().strip_prefix("building '")?;
    let (drv, _) = rest.split_once('\'')?;
    drv.ends_with(".drv").then_some(drv)
}

/// The derivation named by a terminal Nix build failure.
pub(crate) fn realise_failed_drv(line: &str) -> Option<&str> {
    let rest = line.trim_start().strip_prefix("error: Cannot build '")?;
    let (drv, _) = rest.split_once('\'')?;
    drv.ends_with(".drv").then_some(drv)
}

pub(crate) fn failure_excerpt_from_log(log: &[u8]) -> Option<String> {
    if log.is_empty() {
        return None;
    }
    let text = String::from_utf8_lossy(log);
    if text.trim().is_empty() {
        return None;
    }
    let lines: Vec<&str> = text.lines().rev().take(20).collect();
    Some(lines.into_iter().rev().collect::<Vec<_>>().join("\n"))
}

/// A build log proves the derivation ran; no log leaves an infrastructure
/// interruption eligible for retry.
fn build_failure(drv: &str) -> Option<String> {
    let Ok(output) = crate::support::nix::Invocation::plain("log")
        .local_only()
        .operand(drv)
        .probe("a missing log still reports the failure")
    else {
        return None;
    };
    if !output.status.is_success() {
        return None;
    }
    failure_excerpt_from_log(&output.stdout)
}

/// Output paths not yet valid in the local store, chunked to keep argv
/// bounded.
fn invalid_outputs(outputs: &[String]) -> Result<BTreeSet<String>> {
    let mut invalid = BTreeSet::new();
    for chunk in outputs.chunks(500) {
        let probe = crate::support::nix::Invocation::tool("nix-store")
            .args(["--check-validity", "--print-invalid"])
            .operands(chunk.iter().cloned())
            .probe("validity is the completion signal")?;
        invalid.extend(
            String::from_utf8_lossy(&probe.stdout)
                .split_whitespace()
                .map(str::to_string),
        );
    }
    Ok(invalid)
}

/// Batches finished outputs to the signed push store from its own thread, so
/// uploads overlap builds and a cancel keeps everything already copied.
struct Uploader {
    sender: Option<mpsc::Sender<Vec<String>>>,
    handle: Option<std::thread::JoinHandle<()>>,
}

impl Uploader {
    fn start(store: Option<String>) -> Uploader {
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
                        Self::flush(&store, &mut batch);
                        return;
                    }
                }
                Self::flush(&store, &mut batch);
            }
        });
        Uploader {
            sender: Some(sender),
            handle: Some(handle),
        }
    }

    fn flush(store: &str, batch: &mut Vec<String>) {
        if batch.is_empty() {
            return;
        }
        match crate::support::nix::Invocation::plain("copy")
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
        drop(self.sender.take());
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
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
    let uploader = Uploader::start(Some(key.store()));
    uploader.push(report.push.clone());
    uploader.finish();
    Ok(report)
}

const BUILD_ATTEMPTS: usize = 3;

/// Build every case's selected jobs from their evaluated derivations,
/// streaming results to `on_event` as they arrive. Each realise child gets
/// its own process group, so a timeout takes its whole nix tree down.
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

    // The evaluation's answer: every selected job's derivation and outputs.
    let mut jobs: BTreeMap<String, JobSpec> = BTreeMap::new();
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
    fn emit(
        value: Value,
        stream: &mut std::fs::File,
        stream_path: &Path,
        cases: &mut Vec<crate::ci::facts::junit::Case>,
        on_event: &mut dyn FnMut(StreamEvent) -> Result<()>,
    ) -> Result<()> {
        writeln!(stream, "{value}").map_err(|e| io(stream_path, e))?;
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

    fn emit_failure(
        drv: &str,
        error: &str,
        jobs: &BTreeMap<String, JobSpec>,
        build_started: &BTreeMap<String, std::time::Instant>,
        stream: &mut std::fs::File,
        stream_path: &Path,
        cases: &mut Vec<crate::ci::facts::junit::Case>,
        on_event: &mut dyn FnMut(StreamEvent) -> Result<()>,
    ) -> Result<usize> {
        let duration = build_started.get(drv).map(|at| at.elapsed().as_secs_f64());
        for attr in &jobs[drv].attrs {
            emit(
                serde_json::json!({
                    "type": "BUILD", "attr": attr, "drv": drv, "success": false,
                    "error": error, "duration": duration,
                }),
                stream,
                stream_path,
                cases,
                on_event,
            )?;
        }
        Ok(jobs[drv].attrs.len())
    }

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
    // Outputs cached by local validity (a bootstrap build, a previous run's
    // leftovers) are in neither the build nor the fetch set, and nothing has
    // pushed them. They go to the uploader, which skips whatever the remote
    // already has.
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
            pending.insert(drv.clone());
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

    let uploader = Uploader::start(key.as_ref().map(SigningKey::store));
    if key.is_some() && !local_only.is_empty() {
        crate::support::ui::fact("pushing locally built outputs", local_only.len());
        uploader.push(local_only);
    }
    let started = std::time::Instant::now();
    let mut build_started: BTreeMap<String, std::time::Instant> = BTreeMap::new();
    // Announced build-time dependencies, pushed as their outputs turn valid.
    let mut dep_pending: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut timed_out = false;

    for attempt in 1..=BUILD_ATTEMPTS {
        if pending.is_empty() || timed_out {
            break;
        }
        let mut attempt_started = BTreeSet::new();
        let mut cmd = crate::support::nix::Invocation::tool("nix-store")
            .args(["--realise", "--keep-going"])
            .args(["--max-jobs", &request.max_jobs.to_string()])
            .operands(pending.iter().cloned())
            .route(request.route)?
            .command()?;
        let mut child =
            crate::support::tools::spawn(cmd.stdout(Stdio::null()).stderr(Stdio::piped()))?;
        let stderr = child.take_stderr().expect("stderr was piped");
        let (sender, receiver) = mpsc::channel();
        let reader_thread = std::thread::spawn(move || {
            let mut reader = BufReader::new(stderr);
            let mut buffer = Vec::new();
            while matches!(reader.read_until(b'\n', &mut buffer), Ok(n) if n > 0) {
                let line = String::from_utf8_lossy(&buffer).trim_end().to_string();
                let _ = sender.send(line);
                buffer.clear();
            }
        });

        let mut last_poll = std::time::Instant::now();
        let mut recent_deps: std::collections::VecDeque<String> = Default::default();
        loop {
            match receiver.recv_timeout(Duration::from_secs(5)) {
                Ok(line) => {
                    writeln!(log, "{line}").map_err(|e| io(&log_path, e))?;
                    if let Some(drv) = realise_failed_drv(&line) {
                        if pending.contains(drv) {
                            if let Some(error) = build_failure(drv) {
                                pending.remove(drv);
                                failures += emit_failure(
                                    drv,
                                    &error,
                                    &jobs,
                                    &build_started,
                                    &mut stream,
                                    &stream_path,
                                    &mut cases,
                                    on_event,
                                )?;
                            }
                        }
                        on_event(StreamEvent::Output(line))?;
                    } else if let Some(drv) = realise_building_drv(&line) {
                        if let Some(spec) = jobs.get(drv) {
                            attempt_started.insert(drv.to_string());
                            build_started
                                .entry(drv.to_string())
                                .or_insert_with(std::time::Instant::now);
                            for attr in spec.attrs.clone() {
                                on_event(StreamEvent::Output(format!("  building \"{attr}\"")))?;
                            }
                        } else {
                            // `/nix/store/<32-char hash>-name.drv`, name only.
                            let name = drv.get(44..).unwrap_or(drv).trim_end_matches(".drv");
                            if recent_deps.back().map(String::as_str) != Some(name) {
                                recent_deps.push_back(name.to_string());
                                if recent_deps.len() > 4 {
                                    recent_deps.pop_front();
                                }
                            }
                        }
                        if !jobs.contains_key(drv)
                            && needed.contains(drv)
                            && !dep_pending.contains_key(drv)
                        {
                            match drv_outputs(drv) {
                                Ok(outputs) => {
                                    dep_pending.insert(drv.to_string(), outputs);
                                }
                                Err(error) => crate::support::ui::warning(format!(
                                    "not tracking dependency {drv}: {error}"
                                )),
                            }
                        }
                    } else {
                        on_event(StreamEvent::Output(line))?;
                    }
                    on_event(StreamEvent::Activity)?;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    child.wait().map_err(|e| io(&log_path, e))?;
                    break;
                }
            }
            // On the wall clock, never on quiet gaps: a long compile streams
            // its log continuously, and completions, liveness, the hard
            // timeout, and child exit must not wait for stderr to fall
            // silent.
            if last_poll.elapsed() < Duration::from_secs(5) {
                continue;
            }
            last_poll = std::time::Instant::now();
            on_event(StreamEvent::Heartbeat {
                recent_deps: recent_deps.iter().cloned().collect(),
            })?;
            let outputs: Vec<String> = pending
                .iter()
                .flat_map(|drv| jobs[drv].outputs.iter().cloned())
                .collect();
            let invalid = invalid_outputs(&outputs)?;
            let finished: Vec<String> = pending
                .iter()
                .filter(|drv| {
                    jobs[drv.as_str()]
                        .outputs
                        .iter()
                        .all(|out| !invalid.contains(out))
                })
                .cloned()
                .collect();
            for drv in finished {
                pending.remove(&drv);
                let duration = build_started.get(&drv).map(|at| at.elapsed().as_secs_f64());
                for attr in &jobs[&drv].attrs {
                    emit(
                        serde_json::json!({
                            "type": "BUILD", "attr": attr, "drv": drv, "success": true,
                            "duration": duration,
                        }),
                        &mut stream,
                        &stream_path,
                        &mut cases,
                        on_event,
                    )?;
                }
                uploader.push(jobs[&drv].outputs.clone());
            }
            settle_deps(&mut dep_pending, &uploader)?;
            if request
                .hard_timeout
                .is_some_and(|timeout| started.elapsed() >= timeout)
            {
                timed_out = true;
                #[cfg(unix)]
                kill_group(&child).map_err(|e| io(&log_path, e))?;
                child.wait().map_err(|e| io(&log_path, e))?;
                break;
            }
            if child.try_wait().map_err(|e| io(&log_path, e))?.is_some() {
                break;
            }
        }
        let _ = reader_thread.join();
        // The post-exit sweep settles everything the poll missed.
        let outputs: Vec<String> = pending
            .iter()
            .flat_map(|drv| jobs[drv].outputs.iter().cloned())
            .collect();
        let invalid = invalid_outputs(&outputs)?;
        let finished: Vec<String> = pending
            .iter()
            .filter(|drv| {
                jobs[drv.as_str()]
                    .outputs
                    .iter()
                    .all(|out| !invalid.contains(out))
            })
            .cloned()
            .collect();
        for drv in finished {
            pending.remove(&drv);
            let duration = build_started.get(&drv).map(|at| at.elapsed().as_secs_f64());
            for attr in &jobs[&drv].attrs {
                emit(
                    serde_json::json!({
                        "type": "BUILD", "attr": attr, "drv": drv, "success": true,
                        "duration": duration,
                    }),
                    &mut stream,
                    &stream_path,
                    &mut cases,
                    on_event,
                )?;
            }
            uploader.push(jobs[&drv].outputs.clone());
        }
        settle_deps(&mut dep_pending, &uploader)?;
        if !timed_out {
            let built_failures: Vec<(String, String)> = pending
                .iter()
                .filter(|drv| attempt_started.contains(*drv))
                .filter_map(|drv| build_failure(drv).map(|error| (drv.clone(), error)))
                .collect();
            for (drv, error) in built_failures {
                pending.remove(&drv);
                failures += emit_failure(
                    &drv,
                    &error,
                    &jobs,
                    &build_started,
                    &mut stream,
                    &stream_path,
                    &mut cases,
                    on_event,
                )?;
            }
        }
        if !pending.is_empty() && attempt < BUILD_ATTEMPTS && !timed_out {
            crate::support::ui::note(format!(
                "retrying {} builds without logs (attempt {}/{BUILD_ATTEMPTS})",
                pending.len(),
                attempt + 1
            ));
        }
    }

    // Whatever never became valid is a failure, with its log as the story.
    for drv in std::mem::take(&mut pending) {
        let error = if timed_out {
            "the build timed out before this job finished".to_string()
        } else {
            crate::ci::facts::NO_BUILD_LOG.to_string()
        };
        failures += emit_failure(
            &drv,
            &error,
            &jobs,
            &build_started,
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
        push_build_deps(key, &needed)?;
    }
    log.finish()?;
    Ok(if failures == 0 {
        CommandStatus::SUCCESS
    } else {
        CommandStatus::FAILURE
    })
}
