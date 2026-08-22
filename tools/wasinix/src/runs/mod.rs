//! Durable runs: start a command under a detached supervisor, observe it
//! through its run directory, and keep exactly one live writer of run.json
//! (the supervisor), so no observer can clobber a recorded exit. The reaper
//! is the one exception, and only for a supervisor proven dead.

mod collection;
pub mod remote;

pub(crate) use collection::{gc, is_pinned, set_pinned, GcPolicy};
#[cfg(test)]
pub(crate) use collection::gc_under;

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::ci::events::{self, Event};
use crate::support::atoms::RunState;
use crate::support::error::{Error, Result, io, missing};
use crate::support::schema::{self, Document};
use crate::support::time::unix_secs;

pub const RUN_FILE: &str = "run.json";
/// The comment command a run was started for, recorded in the run directory
/// so a run that dies before it plans anything can still say what it was
/// asked to do.
pub const ORIGIN_FILE: &str = "origin-command.json";
pub const LOG_FILE: &str = "run.log";
pub const CANCEL_MARKER: &str = "cancel";
pub const PIN_FILE: &str = "pinned";
const CANCEL_GRACE: Duration = Duration::from_secs(30);
const HEARTBEAT_EVERY: Duration = Duration::from_secs(600);
/// How long a `starting` record may sit without a live supervisor before an
/// observer reports it lost rather than young.
const STARTUP_GRACE_SECS: u64 = 30;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Run {
    pub run_id: String,
    pub command: Vec<String>,
    pub state: RunState,
    /// The supervisor's pid; 0 until it has taken over the record.
    pub pid: u32,
    pub started_at: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<u8>,
}

impl Document for Run {
    const KIND: &'static str = "run";
    const SCHEMA: u32 = 1;
}

/// Where durable runs live. `--run-dir` observers can point anywhere (a
/// downloaded artifact); this is only where new runs are created and ids are
/// resolved.
pub fn registry() -> Result<PathBuf> {
    if let Some(state) = crate::support::env::xdg_state_home() {
        return Ok(state.join("wasinix/runs"));
    }
    Ok(crate::support::shell::home_dir()?.join(".local/state/wasinix/runs"))
}

/// Recorded run ids, newest first, for shell completion: silent on any
/// problem, since a completer must never error a keystroke.
pub fn run_ids() -> Vec<String> {
    let Ok(registry) = registry() else {
        return Vec::new();
    };
    let Ok(entries) = std::fs::read_dir(&registry) else {
        return Vec::new();
    };
    let mut ids: Vec<String> = entries
        .flatten()
        .filter(|entry| entry.path().join(RUN_FILE).exists())
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect();
    ids.sort_by(|a, b| b.cmp(a));
    ids
}

pub fn dir_of(run_id: &str) -> Result<PathBuf> {
    let dir = registry()?.join(run_id);
    if !dir.join(RUN_FILE).exists() {
        return missing(format!(
            "no run {run_id} under {}; `run list` shows what exists",
            registry()?.display()
        ));
    }
    Ok(dir)
}

pub fn list() -> Result<Vec<Run>> {
    let registry = registry()?;
    let mut runs = Vec::new();
    let entries = match std::fs::read_dir(&registry) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(runs),
        Err(error) => return Err(io(&registry, error)),
    };
    for entry in entries {
        let entry = entry.map_err(|e| io(&registry, e))?;
        let run_file = entry.path().join(RUN_FILE);
        if run_file.exists() {
            reap(&entry.path())?;
            runs.push(observed(&entry.path())?);
        }
    }
    runs.sort_by_key(|run| std::cmp::Reverse(run.started_at));
    Ok(runs)
}

/// Whether `pid` is still this run's supervisor. A bare `/proc/<pid>` check
/// would be fooled by pid reuse across a reboot (the registry outlives it),
/// so the process must also name this run's directory in its command line.
fn supervisor_alive(pid: u32, run_dir: &Path) -> bool {
    if pid == 0 {
        return false;
    }
    let cmdline = match std::fs::read(format!("/proc/{pid}/cmdline")) {
        Ok(bytes) => bytes,
        Err(_) => return false,
    };
    // cmdline is NUL-separated argv; the supervise arg carries the run dir.
    let argv = String::from_utf8_lossy(&cmdline);
    let run_dir = run_dir.to_string_lossy();
    argv.split('\0')
        .any(|arg| arg == run_dir || Path::new(arg) == run_dir.as_ref())
}

/// The run log's last words, transfer chatter dropped: the only evidence a
/// run that died before writing a report leaves behind.
pub fn log_tail(run_dir: &Path, limit: usize) -> Option<String> {
    let text = std::fs::read_to_string(run_dir.join(LOG_FILE)).ok()?;
    let kept: String = text
        .lines()
        .filter(|line| !crate::support::nix::progress_noise(line))
        .fold(String::new(), |mut kept, line| {
            kept.push_str(line);
            kept.push('\n');
            kept
        });
    let tail = crate::support::error::tail(&kept, limit);
    (!tail.is_empty()).then_some(tail)
}

/// The run as an observer should report it: a recorded non-final state whose
/// supervisor is gone becomes `lost`, a state like any other.
pub fn observed(run_dir: &Path) -> Result<Run> {
    let mut run: Run = schema::read(&run_dir.join(RUN_FILE))?;
    if !run.state.is_final() {
        let never_started =
            run.pid == 0 && unix_secs().saturating_sub(run.started_at) > STARTUP_GRACE_SECS;
        if never_started || (run.pid != 0 && !supervisor_alive(run.pid, run_dir)) {
            run.state = RunState::Lost;
        }
    }
    Ok(run)
}

fn write_run(run_dir: &Path, run: &Run) -> Result<()> {
    schema::write(&run_dir.join(RUN_FILE), run)
}

/// Record takeover: run.json (created for a never-supervised directory) and
/// the RunStarted event move together.
pub fn record_started(run_dir: &Path) -> Result<()> {
    let mut run: Run = schema::read(&run_dir.join(RUN_FILE)).unwrap_or_default();
    run.pid = std::process::id();
    run.state = RunState::Running;
    if run.started_at == 0 {
        run.started_at = unix_secs();
    }
    write_run(run_dir, &run)?;
    events::append(
        run_dir,
        &Event::RunStarted {
            at: unix_secs(),
            pid: run.pid,
        },
    )
}

/// Record a terminal transition: run.json and the RunFinished event move
/// together, so no observer can see one without the other. Creates run.json
/// when the run was never supervised (a bare `ci exec` directory), so every
/// finished run directory is observable.
pub fn record_finished(run_dir: &Path, state: RunState, exit_code: Option<u8>) -> Result<()> {
    let max_log_bytes = crate::support::env::run_log_bytes()?
        .map(|bytes| bytes as u64)
        .unwrap_or(crate::support::log::DEFAULT_RUN_MAX_BYTES);
    crate::support::log::enforce_budget(run_dir, max_log_bytes)?;
    let mut run: Run = schema::read(&run_dir.join(RUN_FILE)).unwrap_or_default();
    run.state = state;
    run.exit_code = exit_code;
    run.finished_at = Some(unix_secs());
    write_run(run_dir, &run)?;
    events::append(
        run_dir,
        &Event::RunFinished {
            at: unix_secs(),
            state,
            exit_code,
        },
    )
}

/// Persist `lost` for a run in the local registry whose supervisor is
/// provably dead, so the state every observer derives becomes the state on
/// disk and downstream surfaces (the report, the check run) can settle.
/// Never called on a fetched run directory: its pids belong to another host,
/// and rewriting a downloaded verdict would destroy it.
pub fn reap(run_dir: &Path) -> Result<()> {
    if !run_dir.starts_with(registry()?) {
        return Ok(());
    }
    let recorded: Run = schema::read(&run_dir.join(RUN_FILE))?;
    if recorded.state.is_final() {
        return Ok(());
    }
    let observed = observed(run_dir)?;
    if observed.state == RunState::Lost {
        record_finished(run_dir, RunState::Lost, None)?;
    }
    Ok(())
}

/// Start `command` under a detached supervisor and return its run id. The
/// payload always receives the run directory: a literal `{run-dir}` in any
/// payload word is replaced with it (for commands that need the flag at a
/// specific position, like `diff` before its case tail), and a payload
/// carrying no `--run-dir` word gets `--run-dir <dir>` appended. A payload
/// that does not accept it fails immediately and loudly in the run log,
/// which is the contract for what can run durably.
pub fn start(command: &[String]) -> Result<String> {
    if command.is_empty() {
        return Err(Error::Request("run start needs a command to run".into()));
    }
    let registry = registry()?;
    crate::support::fs::create_dir_all(&registry)?;
    let mut run_id = String::new();
    let mut run_dir = PathBuf::new();
    for attempt in 0u32.. {
        let candidate = format!("{}-{}-{attempt}", unix_secs(), std::process::id());
        let dir = registry.join(&candidate);
        match std::fs::create_dir(&dir) {
            Ok(()) => {
                run_id = candidate;
                run_dir = dir;
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => return Err(io(&dir, error)),
        }
    }
    let command: Vec<String> = command
        .iter()
        .map(|word| word.replace("{run-dir}", &run_dir.display().to_string()))
        .collect();

    // Written before the spawn: from here on the supervisor is the only
    // writer, so nothing can regress a state it has recorded.
    write_run(
        &run_dir,
        &Run {
            run_id: run_id.clone(),
            command: command.to_vec(),
            state: RunState::Starting,
            pid: 0,
            started_at: unix_secs(),
            finished_at: None,
            exit_code: None,
        },
    )?;

    let exe = crate::support::env::current_exe()?;
    let mut supervisor = Command::new(exe);
    supervisor
        .arg("run")
        .arg("supervise")
        .arg(&run_dir)
        .args(command)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    crate::support::tools::spawn(&mut supervisor)?.detach();
    Ok(run_id)
}

#[cfg(unix)]
use crate::support::process::signal_group;

/// The supervisor body: run the payload in its own process group with output
/// teed to the run log, record every transition in run.json and the event
/// stream, and honour a cancel marker by killing the payload's group (TERM,
/// then KILL after a grace period).
pub fn supervise(run_dir: &Path, command: &[String]) -> Result<()> {
    let result = supervise_payload(run_dir, command);
    if let Err(error) = &result {
        // The supervisor runs detached with its stderr discarded; an error it
        // does not record reads as `starting` forever to every observer.
        if let Ok(run) = schema::read::<Run>(&run_dir.join(RUN_FILE)) {
            if !run.state.is_final() {
                let _ = events::append(
                    run_dir,
                    &Event::Warning {
                        at: unix_secs(),
                        message: format!("supervisor failed: {error}"),
                    },
                );
                let _ = record_finished(run_dir, RunState::Failed, None);
            }
        }
    }
    result
}

/// The host capacity slot this run holds, when a remote launch asked for one
/// through the lease env. The supervisor owns it for the run's whole life;
/// an exhausted host fails the run loudly rather than overcommitting.
fn host_lease() -> Result<Option<crate::nix::builder::Lease>> {
    let Some(root) = crate::support::env::host_lease_root()? else {
        return Ok(None);
    };
    let capacity = crate::support::env::host_lease_capacity()?.ok_or_else(|| {
        Error::Request(
            "$WASINIX_HOST_LEASE_ROOT is set without $WASINIX_HOST_LEASE_CAPACITY".into(),
        )
    })?;
    let lease = crate::nix::builder::acquire_slots(Path::new(&root), capacity, "this host")?;
    Ok(Some(lease))
}

fn supervise_payload(run_dir: &Path, command: &[String]) -> Result<()> {
    let mut run: Run = schema::read(&run_dir.join(RUN_FILE))?;
    run.pid = std::process::id();
    let _lease = host_lease()?;

    let log_path = run_dir.join(LOG_FILE);
    let log = crate::support::log::SharedLog::create_followed(&log_path)?;
    let mut payload = Command::new(&command[0]);
    payload.args(&command[1..]);
    if !command.iter().any(|word| word == "--run-dir") {
        payload.arg("--run-dir").arg(run_dir);
    }
    payload.stdin(std::process::Stdio::null());
    let stdout_log = log.clone();
    let stderr_log = log.clone();
    let stdout_path = log_path.clone();
    let stderr_path = log_path.clone();
    let (mut child, readers) = crate::support::tools::spawn_piped(
        &mut payload,
        move |mut stream| {
            let mut log = stdout_log;
            std::io::copy(&mut stream, &mut log).map_err(|error| io(&stdout_path, error))?;
            Ok(())
        },
        move |mut stream| {
            let mut log = stderr_log;
            std::io::copy(&mut stream, &mut log).map_err(|error| io(&stderr_path, error))?;
            Ok(())
        },
    )?;
    let payload_group = child.id();

    record_started(run_dir)?;

    let mut cancelled_at: Option<std::time::Instant> = None;
    let mut last_heartbeat = std::time::Instant::now();
    let status = loop {
        if let Some(status) = child.try_wait().map_err(|e| io(&log_path, e))? {
            break status;
        }
        match cancelled_at {
            None if run_dir.join(CANCEL_MARKER).exists() => {
                cancelled_at = Some(std::time::Instant::now());
                #[cfg(unix)]
                signal_group(payload_group, libc::SIGTERM).map_err(|e| io(&log_path, e))?;
            }
            Some(since) if since.elapsed() >= CANCEL_GRACE => {
                #[cfg(unix)]
                signal_group(payload_group, libc::SIGKILL).map_err(|e| io(&log_path, e))?;
            }
            _ => {}
        }
        if last_heartbeat.elapsed() >= HEARTBEAT_EVERY {
            events::append(
                run_dir,
                &Event::Heartbeat {
                    at: unix_secs(),
                    detail: None,
                },
            )?;
            last_heartbeat = std::time::Instant::now();
        }
        std::thread::sleep(Duration::from_millis(200));
    };

    // The payload is gone; anything still alive in its group survived the
    // TERM (a signal-shy child like `timeout`) and would run orphaned.
    #[cfg(unix)]
    signal_group(payload_group, libc::SIGKILL).map_err(|e| io(&log_path, e))?;
    readers.join(&payload)?;
    log.finish()?;
    let exit = crate::support::process::CommandStatus::from_exit(status);
    // A clean exit is honest even if a cancel raced in: the payload finished
    // its work before the signal could stop it, so it completed, not
    // cancelled. Only a payload the cancel actually cut short is cancelled.
    run.state = if exit.is_success() {
        RunState::Complete
    } else if cancelled_at.is_some() {
        RunState::Cancelled
    } else {
        RunState::Failed
    };
    run.exit_code = Some(exit.code());
    record_finished(run_dir, run.state, run.exit_code)?;
    if run.state == RunState::Failed {
        Err(Error::Failure(format!(
            "run {} failed with exit code {}",
            run.run_id,
            exit.code()
        )))
    } else {
        Ok(())
    }
}

/// Request cancellation. Only the marker comes from here; the supervisor
/// signals the payload group and records the outcome, so the recorded exit
/// can never be clobbered by a racing observer.
pub fn cancel(run_id: &str) -> Result<()> {
    let run_dir = dir_of(run_id)?;
    let run = observed(&run_dir)?;
    if run.state.is_final() {
        return Err(Error::Request(format!(
            "run {run_id} already finished as {:?}",
            run.state
        )));
    }
    crate::support::fs::write(&run_dir.join(CANCEL_MARKER), b"")
}

/// Print the run log's tail, then keep following it until the run is final.
/// Reads by offset, so a log that rotates out from under us errors rather
/// than silently repeating.
pub fn follow_logs(run_dir: &Path, follow: bool) -> Result<()> {
    use std::io::{Read, Seek, SeekFrom, Write};
    const TAIL_BYTES: u64 = 64 * 1024;
    let path = run_dir.join(LOG_FILE);
    let tail = crate::support::fs::tail(&path, TAIL_BYTES)?;
    let mut stdout = std::io::stdout();
    stdout
        .write_all(tail.as_bytes())
        .map_err(|e| io(&path, e))?;
    if !follow {
        return Ok(());
    }
    let mut offset = std::fs::metadata(&path).map_err(|e| io(&path, e))?.len();
    loop {
        let run = observed(run_dir)?;
        let len = std::fs::metadata(&path).map_err(|e| io(&path, e))?.len();
        if len < offset {
            return Err(Error::Failure(format!(
                "{} shrank while following it",
                path.display()
            )));
        }
        if len > offset {
            let mut file = std::fs::File::open(&path).map_err(|e| io(&path, e))?;
            file.seek(SeekFrom::Start(offset))
                .map_err(|e| io(&path, e))?;
            let mut chunk = Vec::new();
            file.read_to_end(&mut chunk).map_err(|e| io(&path, e))?;
            stdout.write_all(&chunk).map_err(|e| io(&path, e))?;
            stdout.flush().map_err(|e| io(&path, e))?;
            offset = len;
        } else if run.state.is_final() {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// Wait for a final state, with a bounded patience for the observer even
/// though the run itself keeps going.
pub fn wait(run_id: &str, timeout: Option<Duration>) -> Result<Run> {
    let run_dir = dir_of(run_id)?;
    crate::support::poll::until(
        crate::support::poll::Options {
            interval: Duration::from_secs(2),
            deadline: timeout,
            max_consecutive_failures: 5,
        },
        || {
            let run = observed(&run_dir)?;
            if run.state.is_final() {
                Ok(crate::support::poll::Poll::Ready(run))
            } else {
                Ok(crate::support::poll::Poll::Pending)
            }
        },
    )
}
