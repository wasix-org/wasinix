//! Run a wasinix command durably on a remote host. The host supervises it as
//! an ordinary durable run; the observer ships the checkout, starts the run,
//! and tails the run's own event stream, so losing the observer never loses
//! the run and joining mid-run reads the same records.

use std::path::{Path, PathBuf};

use crate::ci::events::{self, Event};
use crate::nix::builder::{self, Builder, Deadline};
use crate::nix::route::{default_eval_workers, EvaluationLimits};
use crate::runs::{Run, RUN_FILE};
use crate::support::error::{io, request_error, Error, Result};
use crate::support::process::CommandStatus;
use crate::support::shell::quote;
use crate::support::{git, schema, tools};

const POLL_INTERVAL: std::time::Duration = std::time::Duration::from_secs(5);
const MAX_POLL_FAILURES: u32 = 12;
const RUN_MARKER: &str = "===WASINIX-RUN===";
const EVENTS_MARKER: &str = "===WASINIX-EVENTS===";

pub struct Request<'a> {
    pub repo: &'a Path,
    pub builder: &'a Builder,
    /// Files shipped into the remote staging directory before launch.
    pub inputs: Vec<(PathBuf, String)>,
    /// The wasinix command the host's `run start` supervises, built against
    /// the remote staging directory the shipped inputs land in.
    pub payload: &'a dyn Fn(&str) -> Vec<String>,
    /// Local directory the finished run is copied into.
    pub fetch_to: &'a Path,
    /// Sink for the mirrored event stream while the run executes.
    pub progress: &'a mut dyn FnMut(&Event),
}

fn flake_source(repo: &Path) -> Result<String> {
    let value = crate::support::nix::Invocation::plain("flake prefetch")
        .accepts_flake_config()
        .json()
        .workdir(repo)
        .run_json("prefetching the flake source")?;
    value["storePath"]
        .as_str()
        .map(str::to_string)
        .ok_or_else(|| Error::Request("flake source has no store path".into()))
}

struct TemporaryFiles(Vec<PathBuf>);

impl Drop for TemporaryFiles {
    fn drop(&mut self) {
        for path in &self.0 {
            let _ = std::fs::remove_file(path);
        }
    }
}

fn copy_to_host(builder: &Builder, local: &Path, remote_path: &str) -> Result<()> {
    let mut cmd = builder.scp(Deadline::Transfer)?;
    cmd.arg(local)
        .arg(format!("{}:{remote_path}", builder.host));
    tools::log(&cmd);
    if !tools::status(&mut cmd)?.success() {
        return request_error(format!(
            "could not copy {} to {}",
            local.display(),
            builder.host
        ));
    }
    Ok(())
}

/// The launch script: reconstruct the checkout, then hand the payload to the
/// host's own `run start`, which detaches its supervisor, so this returns as
/// soon as the run id is known. The lease env hands capacity enforcement to
/// that supervisor, which outlives this script.
pub(crate) fn launch_script(
    builder: &Builder,
    state: &str,
    head: &str,
    source: &str,
    limits: EvaluationLimits,
    payload: &[String],
) -> String {
    let state = quote(state);
    let payload = payload
        .iter()
        .map(|word| quote(word))
        .collect::<Vec<_>>()
        .join(" ");
    // The payload names the launcher binary explicitly: the supervisor runs
    // an ordinary program, and the launcher carries the tools the payload
    // needs on PATH.
    format!(
        "set -eu\n\
         {load_check}\
         git clone --quiet {state}/repo.bundle {state}/repo\n\
         git -C {state}/repo checkout --quiet --detach {head}\n\
         if [ -s {state}/working.patch ]; then git -C {state}/repo apply --index --binary {state}/working.patch; fi\n\
         cd {state}/repo\n\
         export WASINIX_EVAL_WORKERS={workers}\n\
         export WASINIX_EVAL_MEMORY={memory}\n\
         export WASINIX_EVAL_TIMEOUT_SECONDS={timeout}\n\
         export WASINIX_HOST_LEASE_ROOT=\"${{XDG_RUNTIME_DIR:-/tmp}}/wasinix/leases/{name}\"\n\
         export WASINIX_HOST_LEASE_CAPACITY={capacity}\n\
         bin=\"$(nix build --print-out-paths --no-link --accept-flake-config {flake}#wasinix)/bin/wasinix\"\n\
         id=$(\"$bin\" run start -- \"$bin\" {payload})\n\
         printf 'WASINIX_RUN_DIR %s/wasinix/runs/%s\\n' \"${{XDG_STATE_HOME:-$HOME/.local/state}}\" \"$id\"\n",
        load_check = crate::nix::builder::load_check_script(builder),
        head = quote(head),
        workers = limits.workers,
        memory = limits.memory,
        timeout = limits.timeout.as_secs(),
        name = quote(&builder.name),
        capacity = builder.capacity,
        flake = quote(&format!("path:{source}")),
    )
}

/// One poll's shell command: liveness of the supervisor, the run record, and
/// the event stream from the byte offset already mirrored. Liveness matches
/// the run dir in the supervisor's argv, as the local check does: a bare
/// kill -0 would report a recycled pid as alive forever.
fn poll_command(run_dir: &str, pid: u32, offset: u64) -> String {
    let dir = quote(run_dir);
    format!(
        "if [ {pid} -ne 0 ] && tr '\\0' '\\n' < /proc/{pid}/cmdline 2>/dev/null | grep -qxF -- {dir}; then printf 'alive\\n'; else printf 'dead\\n'; fi\n\
         printf '%s\\n' '{RUN_MARKER}'\n\
         cat {dir}/{RUN_FILE} 2>/dev/null || true\n\
         printf '\\n%s\\n' '{EVENTS_MARKER}'\n\
         tail -c +{start} {dir}/{events} 2>/dev/null || true\n",
        start = offset + 1,
        events = events::FILE,
    )
}

pub(crate) struct Poll {
    pub alive: bool,
    pub run: Option<Run>,
    pub events_chunk: Vec<u8>,
}

pub(crate) fn parse_poll(output: &[u8]) -> Result<Poll> {
    let run_marker = format!("\n{RUN_MARKER}\n");
    let events_marker = format!("\n{EVENTS_MARKER}\n");
    let text = |bytes: &[u8]| String::from_utf8_lossy(bytes).into_owned();
    let find = |haystack: &[u8], needle: &str| -> Option<usize> {
        haystack
            .windows(needle.len())
            .position(|window| window == needle.as_bytes())
    };
    let run_at = find(output, &run_marker)
        .ok_or_else(|| Error::Failure("poll output carries no run marker".into()))?;
    let rest = &output[run_at + run_marker.len()..];
    let events_at = find(rest, &events_marker)
        .ok_or_else(|| Error::Failure("poll output carries no events marker".into()))?;

    let alive = text(&output[..run_at]).trim() == "alive";
    let run_text = text(&rest[..events_at]);
    let run = if run_text.trim().is_empty() {
        None
    } else {
        Some(schema::from_value(
            serde_json::from_str(&run_text).map_err(|source| Error::Json {
                path: "<remote run.json>".into(),
                source,
            })?,
            "<remote run.json>",
        )?)
    };
    Ok(Poll {
        alive,
        run,
        events_chunk: rest[events_at + events_marker.len()..].to_vec(),
    })
}

fn fetch_run(builder: &Builder, run_dir: &str, fetch_to: &Path) -> Result<()> {
    crate::support::fs::create_dir_all(fetch_to)?;
    let scratch = crate::support::fs::Scratch::create("wasinix-fetch")?;
    let mut cmd = builder.scp(Deadline::Transfer)?;
    cmd.arg("-r")
        .arg(format!("{}:{run_dir}/.", builder.host))
        .arg(scratch.path());
    tools::log(&cmd);
    if !tools::status(&mut cmd)?.success() {
        return request_error(format!(
            "could not retrieve remote run from {}:{run_dir}",
            builder.host
        ));
    }
    // When `fetch_to` is a supervised local run (a durable observer), its
    // run.json, run.log, and events.jsonl belong to the local lifecycle;
    // the remote copies must not replace them. A fresh directory takes
    // everything, so a fetched remote run stays self-describing.
    for entry in
        std::fs::read_dir(scratch.path()).map_err(|e| io(scratch.path(), e))?
    {
        let entry = entry.map_err(|e| io(scratch.path(), e))?;
        let name = entry.file_name();
        let target = fetch_to.join(&name);
        let lifecycle = [
            std::ffi::OsStr::new(crate::runs::RUN_FILE),
            std::ffi::OsStr::new(crate::runs::LOG_FILE),
            std::ffi::OsStr::new(events::FILE),
        ]
        .contains(&name.as_os_str());
        if lifecycle && target.exists() {
            continue;
        }
        if target.exists() {
            if target.is_dir() {
                std::fs::remove_dir_all(&target).map_err(|e| io(&target, e))?;
            } else {
                std::fs::remove_file(&target).map_err(|e| io(&target, e))?;
            }
        }
        crate::support::fs::copy_tree_entry(&entry.path(), &target)?;
    }
    Ok(())
}

/// Fetch the finished run, warning rather than failing: the run's own verdict
/// is already known, so a retrieval hiccup must not discard it.
fn fetch_best_effort(builder: &Builder, run_dir: &str, fetch_to: &Path) {
    if let Err(error) = fetch_run(builder, run_dir, fetch_to) {
        crate::support::ui::warning(format!(
            "could not fetch the finished run from {}: {error}",
            builder.host
        ));
    }
}

/// Attach to a running remote run: mirror its event stream into `fetch_to`,
/// narrate progress, and fetch the whole run directory once it is final.
pub fn observe(
    builder: &Builder,
    run_dir: &str,
    fetch_to: &Path,
    progress: &mut dyn FnMut(&Event),
) -> Result<CommandStatus> {
    crate::support::fs::create_dir_all(fetch_to)?;
    // The remote byte position lives in its own sidecar: `fetch_to` can be a
    // supervised local run whose own writer also appends to events.jsonl,
    // so the mirror's length is not the remote offset.
    let offset_path = fetch_to.join("remote-events.offset");
    let mut remote_offset: u64 = std::fs::read_to_string(&offset_path)
        .ok()
        .and_then(|text| text.trim().parse().ok())
        .unwrap_or(0);
    let mut carry: Vec<u8> = Vec::new();
    let mut pid = 0u32;
    let mut failures = 0u32;
    let mut dead_polls = 0u32;
    let mut starting_polls = 0u32;
    loop {
        std::thread::sleep(POLL_INTERVAL);
        // Quiet by contract: this fires every few seconds for the whole
        // run, and a logged poll would flood the transcript.
        let mut cmd = builder.ssh(Deadline::Poll)?;
        cmd.arg(poll_command(run_dir, pid, remote_offset));
        let output = match tools::output(&mut cmd) {
            Ok(output) if output.status.success() => output,
            _ => {
                failures += 1;
                if failures >= MAX_POLL_FAILURES {
                    return request_error(format!(
                        "lost contact with {}:{run_dir}; the run keeps going and can be observed again",
                        builder.host
                    ));
                }
                continue;
            }
        };
        failures = 0;
        let poll = parse_poll(&output.stdout)?;
        remote_offset += poll.events_chunk.len() as u64;
        let fresh = events::ingest_chunk(fetch_to, &mut carry, &poll.events_chunk)?;
        // Persist only the complete-line boundary: a restarted observer has
        // no carry, so it must re-fetch the torn tail whole.
        crate::support::fs::write(
            &offset_path,
            (remote_offset - carry.len() as u64).to_string().as_bytes(),
        )?;
        for event in &fresh {
            progress(event);
        }
        let Some(run) = poll.run else {
            continue;
        };
        pid = run.pid;
        if run.state.is_final() {
            // The outcome is reported before the fetch, and the fetch is
            // best-effort, so a retrieval error cannot mask what the run did.
            crate::support::ui::result(format!("{}: {}", run.run_id, run.state));
            fetch_best_effort(builder, run_dir, fetch_to);
            return Ok(run.state.exit(run.exit_code));
        }
        // A live record with a dead supervisor is a lost run; one dead poll
        // can be a race with a starting supervisor, two is a verdict. A pid
        // that never leaves 0 is a supervisor that never took over, judged by
        // poll count rather than the remote clock.
        if pid == 0 {
            starting_polls += 1;
            if starting_polls >= 8 {
                fetch_best_effort(builder, run_dir, fetch_to);
                return request_error(format!(
                    "run at {}:{run_dir} never left starting; its supervisor died before taking over",
                    builder.host
                ));
            }
        } else if !poll.alive {
            dead_polls += 1;
            if dead_polls >= 2 {
                fetch_best_effort(builder, run_dir, fetch_to);
                return request_error(format!(
                    "run at {}:{run_dir} lost its supervisor",
                    builder.host
                ));
            }
        } else {
            dead_polls = 0;
        }
    }
}

/// Ship the checkout and inputs, start the run under the host's supervisor,
/// and observe it to completion.
pub fn run(request: Request<'_>) -> Result<CommandStatus> {
    let _lease = builder::acquire(request.builder)?;
    crate::support::ui::fact("shipping checkout", &request.builder.host);
    let source = flake_source(request.repo)?;
    // The builder's own store URL: a configured store_url override applies
    // here too, not only to the store route.
    let host_store = request.builder.store();
    let copied = crate::support::nix::Invocation::plain("copy")
        .args(["--to", &host_store])
        .operand(&source)
        .status()?;
    if !copied.is_success() {
        return request_error(format!(
            "could not copy source to {}",
            request.builder.host
        ));
    }

    let nonce = format!(
        "{}-{}",
        crate::support::time::unix_nanos(),
        std::process::id()
    );
    let bundle = crate::support::env::temp_dir().join(format!("wasinix-{nonce}.bundle"));
    let patch = crate::support::env::temp_dir().join(format!("wasinix-{nonce}.patch"));
    let _temporary = TemporaryFiles(vec![bundle.clone(), patch.clone()]);
    git::git_logged(
        request.repo,
        &[
            "bundle",
            "create",
            "--quiet",
            &bundle.to_string_lossy(),
            "--all",
            "HEAD",
        ],
    )
    .map_err(|error| {
        Error::Request(format!(
            "could not bundle the checkout for the remote run: {error}"
        ))
    })?;
    crate::support::fs::write(
        &patch,
        crate::ci::workspace::working_patch(request.repo)?.as_bytes(),
    )?;
    let head = git::resolve_rev(request.repo, "HEAD")?;

    let state = request.builder.ssh_output(Deadline::Probe, &format!(
        "state=\"${{XDG_STATE_HOME:-$HOME/.local/state}}/wasinix/staging/{nonce}\"; mkdir -p \"$state\"; printf '%s\\n' \"$state\""
    ))?;
    let state = state.trim().to_string();
    if state.is_empty() {
        return request_error("remote host returned an empty staging directory");
    }
    copy_to_host(request.builder, &bundle, &format!("{state}/repo.bundle"))?;
    copy_to_host(request.builder, &patch, &format!("{state}/working.patch"))?;
    for (local, name) in &request.inputs {
        copy_to_host(request.builder, local, &format!("{state}/{name}"))?;
    }

    let limits = EvaluationLimits::configured(
        request.builder,
        default_eval_workers(builder::RouteKind::Host),
    )?;
    let script = launch_script(
        request.builder,
        &state,
        head.full(),
        &source,
        limits,
        &(request.payload)(&state),
    );
    let launched = request.builder.ssh_output(Deadline::Launch, &script)?;
    let run_dir = launched
        .lines()
        .find_map(|line| line.strip_prefix("WASINIX_RUN_DIR "))
        .map(str::to_string)
        .ok_or_else(|| Error::Failure("remote launch reported no run directory".into()))?;
    crate::support::ui::fact("remote run", format!("{}:{run_dir}", request.builder.host));

    observe(request.builder, &run_dir, request.fetch_to, request.progress)
}

/// Ask the remote supervisor to stop its payload, through the same marker a
/// local cancel uses. `run` names either a run id in the host's registry or
/// a full run directory, matching the `host:run` handle a launch prints.
pub fn cancel(builder: &Builder, run: &str) -> Result<()> {
    let dir = if run.starts_with('/') {
        quote(run)
    } else {
        format!(
            "\"${{XDG_STATE_HOME:-$HOME/.local/state}}/wasinix/runs/\"{}",
            quote(run)
        )
    };
    builder.ssh_output(Deadline::Probe, &format!(
        "dir={dir}\n\
         if [ ! -f \"$dir/{run_file}\" ]; then echo \"no run at $dir on this host\" >&2; exit 1; fi\n\
         touch \"$dir/{marker}\"",
        run_file = crate::runs::RUN_FILE,
        marker = crate::runs::CANCEL_MARKER,
    ))?;
    Ok(())
}
