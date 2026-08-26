//! Concurrent update PRs on one runner: shared discovery, one isolated
//! worktree per target, and one aggregate result.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::ExitStatus;
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::support::error::{Error, Result, io, request_error};
use crate::support::process::CommandStatus;
use crate::support::{schema, ui};
use crate::update::Mode;
use crate::update::changeset::ChangeSet;
use crate::update::targets::Target;

const HEARTBEAT: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct WorkItem {
    pub name: String,
    pub spec: String,
    release_work: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetResult {
    pub target: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changes: Option<ChangeSet>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pull_request: Option<u64>,
    pub duration_seconds: u64,
}

impl TargetResult {
    fn failed(&self) -> bool {
        self.error.is_some()
            || self
                .changes
                .as_ref()
                .is_some_and(|changes| !changes.failures.is_empty())
    }

    fn changed(&self) -> bool {
        self.changes.as_ref().is_some_and(ChangeSet::changed)
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub targets: Vec<TargetResult>,
}

impl schema::Document for Report {
    const KIND: &'static str = "updateBatch";
    const SCHEMA: u32 = 1;
}

impl Report {
    pub fn status(&self) -> CommandStatus {
        if self.targets.iter().any(TargetResult::failed) {
            CommandStatus::FAILURE
        } else {
            CommandStatus::SUCCESS
        }
    }

    pub fn render(&self) {
        for result in &self.targets {
            if let Some(changes) = &result.changes {
                let mut lines = changes.receipt();
                lines.pop();
                for line in lines {
                    ui::result(line);
                }
            } else if let Some(error) = &result.error {
                ui::result(format!("✗ {}  {error}", result.target));
            }
        }
        let changed = self
            .targets
            .iter()
            .filter(|result| result.changed())
            .count();
        let failed = self.targets.iter().filter(|result| result.failed()).count();
        ui::result(ui::counts(&[
            format!("{} targets", self.targets.len()),
            format!("{changed} updated"),
            format!("{failed} failed"),
        ]));
    }
}

fn request_spec(name: &str, request: &crate::update::Request) -> Result<String> {
    match request.mode {
        Mode::Release => Ok(format!("{name}@{}", request.value)),
        Mode::Revision => {
            let revision = if request.value.is_empty() {
                request
                    .source
                    .as_ref()
                    .and_then(|source| source["rev"].as_str())
                    .ok_or_else(|| {
                        Error::Failure(format!("revision request for {name} carries no revision"))
                    })?
            } else {
                &request.value
            };
            Ok(format!("{name}@rev:{revision}"))
        }
    }
}

pub(crate) fn work_items(targets: &[Target], all: bool, specs: &[String]) -> Result<Vec<WorkItem>> {
    if all && !specs.is_empty() {
        return request_error("--all cannot be combined with target arguments");
    }
    if !all && specs.is_empty() {
        return request_error("update needs --all or at least one target");
    }
    let mut items = if all {
        targets
            .iter()
            .map(|target| WorkItem {
                name: target.name.clone(),
                spec: target.name.clone(),
                release_work: true,
            })
            .collect::<Vec<_>>()
    } else {
        let domain = crate::update::targets::domain(targets);
        let (names, requests) = crate::update::select::target_requests(targets, &domain, specs)?;
        names
            .into_iter()
            .map(|name| {
                let spec = match requests.get(&name) {
                    Some(request) => request_spec(&name, request)?,
                    None => name.clone(),
                };
                let release_work = requests
                    .get(&name)
                    .is_none_or(|request| request.mode == Mode::Release);
                Ok(WorkItem {
                    name,
                    spec,
                    release_work,
                })
            })
            .collect::<Result<Vec<_>>>()?
    };
    items.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(items)
}

pub struct Options {
    pub jobs: usize,
    pub repository: Option<String>,
    pub base: String,
    pub branch: Option<String>,
    pub fork: bool,
}

struct Running {
    item: WorkItem,
    _worktree: crate::ci::workspace::Worktree,
    child: crate::support::tools::Child,
    readers: crate::support::tools::PipeReaders,
    stdout: PathBuf,
    stderr: PathBuf,
    started: Instant,
}

fn spawn(
    repo: &Path,
    revision: &str,
    scratch: &Path,
    sequence: usize,
    item: WorkItem,
    preflight: &Path,
    options: &Options,
) -> Result<Running> {
    let worktree = crate::ci::workspace::Worktree::add(repo, revision)?;
    let stdout = scratch.join(format!("{sequence}.stdout"));
    let stderr = scratch.join(format!("{sequence}.stderr"));
    let stdout_log = crate::support::log::BoundedLog::create(&stdout)?;
    let stderr_log = crate::support::log::BoundedLog::create(&stderr)?;
    let executable = crate::support::env::current_exe()?;
    let branch = options
        .branch
        .clone()
        .unwrap_or_else(|| format!("auto/update-{}", item.name));
    let mut command = crate::support::tools::Process::new(executable);
    command
        .current_dir(worktree.path())
        .args(["--color", "never", "update"])
        .arg(&item.spec)
        .arg("--batch-preflight")
        .arg(preflight)
        .args([
            "--pr",
            "--branch",
            &branch,
            "--base",
            &options.base,
            "--json",
        ])
        .stdin_null();
    if let Some(repository) = &options.repository {
        command.args(["--repository", repository]);
    }
    if options.fork {
        command.arg("--fork");
    }
    ui::fact("update", format!("starting {}", item.name));
    let stdout_path = stdout.clone();
    let stderr_path = stderr.clone();
    let (child, readers) = command.start_piped(
        move |mut stream| {
            let mut log = stdout_log;
            std::io::copy(&mut stream, &mut log).map_err(|error| io(&stdout_path, error))?;
            log.finish()?;
            Ok(())
        },
        move |mut stream| {
            let mut log = stderr_log;
            std::io::copy(&mut stream, &mut log).map_err(|error| io(&stderr_path, error))?;
            log.finish()?;
            Ok(())
        },
    )?;
    Ok(Running {
        item,
        _worktree: worktree,
        child,
        readers,
        stdout,
        stderr,
        started: Instant::now(),
    })
}

fn pull_request(stderr: &str) -> Option<u64> {
    stderr
        .lines()
        .rev()
        .find_map(|line| line.strip_prefix("pull request: ")?.trim().parse().ok())
}

fn completed(running: Running, status: ExitStatus) -> Result<TargetResult> {
    let Running {
        item,
        _worktree,
        child,
        readers,
        stdout,
        stderr,
        started,
    } = running;
    readers.join()?;
    drop(child);
    let stdout_text = crate::support::fs::read_to_string(&stdout)?;
    let stderr_text = crate::support::fs::read_to_string(&stderr)?;
    let value = serde_json::from_str(&stdout_text).ok();
    let changes = value
        .clone()
        .and_then(|value| schema::from_value::<ChangeSet>(value, "update worker").ok());
    let changes_failed = changes
        .as_ref()
        .is_some_and(|changes| !changes.failures.is_empty());
    let error = if changes.is_some() && (status.success() || changes_failed) {
        None
    } else {
        value
            .as_ref()
            .and_then(|value| value["message"].as_str())
            .map(str::to_string)
            .or_else(|| {
                let evidence = if stderr_text.trim().is_empty() {
                    &stdout_text
                } else {
                    &stderr_text
                };
                (!evidence.trim().is_empty())
                    .then(|| crate::support::tools::diagnostics_tail(evidence))
            })
            .or_else(|| Some(format!("worker exited {}", status.code().unwrap_or(1))))
    };
    let result = TargetResult {
        target: item.name,
        changes,
        error,
        pull_request: pull_request(&stderr_text),
        duration_seconds: started.elapsed().as_secs(),
    };
    let outcome = if result.failed() {
        "failed"
    } else if result.changed() {
        "updated"
    } else {
        "up to date"
    };
    let pull = result
        .pull_request
        .map(|number| format!(" · pull request {number}"))
        .unwrap_or_default();
    ui::fact(
        "update",
        format!(
            "{} · {outcome}{pull} · took {}",
            result.target,
            crate::support::format::duration(result.duration_seconds as f64)
        ),
    );
    if result.failed() {
        let evidence = result
            .error
            .clone()
            .or_else(|| {
                result
                    .changes
                    .as_ref()
                    .and_then(|changes| changes.failures.first())
                    .map(|failure| failure.message.clone())
            })
            .unwrap_or_else(|| format!("worker exited {}", status.code().unwrap_or(1)));
        ui::error(format!("{}: {evidence}", result.target));
    }
    Ok(result)
}

fn prepare(
    repo: &Path,
    all: bool,
    specs: &[String],
) -> Result<(Vec<WorkItem>, crate::update::drive::Preflight)> {
    let started = Instant::now();
    ui::fact("updates", "discovering targets and preparing shared state");
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    std::thread::scope(|scope| {
        scope.spawn(move || {
            let result = (|| {
                let snapshot = crate::update::snapshot::load(repo)?;
                let targets = crate::update::targets::all_targets(repo, &snapshot)?;
                let items = work_items(&targets, all, specs)?;
                let release_work = items.iter().any(|item| item.release_work);
                let preflight = crate::update::drive::Preflight::collect(
                    repo,
                    targets,
                    &snapshot,
                    release_work,
                )?;
                Ok((items, preflight))
            })();
            let _ = sender.send(result);
        });
        loop {
            match receiver.recv_timeout(HEARTBEAT) {
                Ok(result) => break result,
                Err(RecvTimeoutError::Timeout) => ui::fact(
                    "updates",
                    format!(
                        "preparing shared state · running for {}",
                        crate::support::format::duration(started.elapsed().as_secs_f64())
                    ),
                ),
                Err(RecvTimeoutError::Disconnected) => {
                    break Err(Error::Failure("update preparation stopped".into()));
                }
            }
        }
    })
}

pub fn run(repo: &Path, all: bool, specs: &[String], options: Options) -> Result<Report> {
    if options.jobs == 0 {
        return request_error("--jobs must be at least 1");
    }
    if !crate::support::git::git(repo, &["status", "--porcelain"])?
        .trim()
        .is_empty()
    {
        return request_error("update PRs need a clean checkout");
    }
    let revision = crate::support::git::git(repo, &["rev-parse", "HEAD"])?;
    let scratch = crate::support::fs::Scratch::create("wasinix-update-batch")?;
    let prepare_started = Instant::now();
    let (items, preflight) = prepare(repo, all, specs)?;
    if items.len() > 1 && options.branch.is_some() {
        return request_error("--branch names one branch and needs exactly one update target");
    }
    let preflight_path = scratch.path().join("preflight.json");
    schema::write(&preflight_path, &preflight)?;
    let total = items.len();
    ui::fact(
        "updates",
        format!(
            "shared state ready · {total} targets · took {}",
            crate::support::format::duration(prepare_started.elapsed().as_secs_f64())
        ),
    );
    let started = Instant::now();
    let mut queued: VecDeque<WorkItem> = items.into();
    let mut running: Vec<Running> = Vec::new();
    let mut results = Vec::new();
    let mut sequence = 0usize;
    let mut next_heartbeat = Instant::now() + HEARTBEAT;
    while !queued.is_empty() || !running.is_empty() {
        while running.len() < options.jobs {
            let Some(item) = queued.pop_front() else {
                break;
            };
            running.push(spawn(
                repo,
                &revision,
                scratch.path(),
                sequence,
                item,
                &preflight_path,
                &options,
            )?);
            sequence += 1;
        }
        let mut finished = None;
        for (index, worker) in running.iter_mut().enumerate() {
            if let Some(status) = worker
                .child
                .try_wait()
                .map_err(|error| io(&worker.stderr, error))?
            {
                finished = Some((index, status));
                break;
            }
        }
        if let Some((index, status)) = finished {
            let worker = running.swap_remove(index);
            results.push(completed(worker, status)?);
            continue;
        }
        if Instant::now() >= next_heartbeat {
            let names = running
                .iter()
                .map(|worker| worker.item.name.as_str())
                .collect::<Vec<_>>()
                .join(", ");
            ui::fact(
                "updates",
                format!(
                    "{}/{} finished · {} running ({names}) · {} queued · running for {}",
                    results.len(),
                    total,
                    running.len(),
                    queued.len(),
                    crate::support::format::duration(started.elapsed().as_secs_f64())
                ),
            );
            next_heartbeat += HEARTBEAT;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    results.sort_by(|left, right| left.target.cmp(&right.target));
    Ok(Report { targets: results })
}
