//! Build selected CI jobs with nix-fast-build, and push what it leaves
//! behind. `--copy-to` uploads runtime closures only, so build-only
//! dependencies are captured from the evaluation before the build and pushed
//! after it; with no signing key there is no upload at all.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::mpsc;
use std::time::Duration;

use serde_json::Value;

use crate::support::error::{io, request_error, Result};
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
    pub eval_workers: usize,
    pub eval_memory: usize,
    pub max_jobs: usize,
    pub hard_timeout: Option<Duration>,
    /// Whether to sign and push; the signing key still has to be present.
    pub push: bool,
}

pub enum StreamEvent {
    Result(Value),
    Activity,
    Heartbeat,
    Output(String),
}

fn renderer_heartbeat(line: &str) -> bool {
    let line = line.to_ascii_lowercase();
    line.contains("heartbeat") || line.contains("still running")
}

fn terminal_renderer_error(line: &str) -> bool {
    line.starts_with("ERROR:nix_fast_build:nix-eval-jobs exited with")
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
        let path = crate::support::env::temp_dir().join(format!("wasinix-key-{}", std::process::id()));
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
        format!("{}&secret-key={}", crate::support::nix::cache_push_store(), self.path.display())
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

fn needed_builds_for(path: &Path, wanted: &[String]) -> Result<Vec<String>> {
    let text = crate::support::fs::read_to_string(path)?;
    let mut needed = Vec::new();
    for job in crate::nix::evaljobs::parse_file(&text)? {
        if wanted.contains(&job.name()) {
            needed.extend(job.needed_builds);
        }
    }
    needed.sort();
    needed.dedup();
    Ok(needed)
}

pub(crate) fn union_expression(cases: &[UnionCase]) -> Result<String> {
    let json = |value: &str| -> Result<String> {
        serde_json::to_string(value).map_err(|source| crate::support::error::Error::Json {
            path: "<union expression>".into(),
            source,
        })
    };
    let mut selected = Vec::new();
    let system = json(crate::support::nix::SYSTEM)?;
    for case in cases {
        let prefix = json(&case.id)?;
        let flake = json(&format!("path:{}", case.worktree.display()))?;
        let names: BTreeMap<&str, Option<()>> =
            case.jobs.iter().map(|name| (name.as_str(), None)).collect();
        let names = json(&serde_json::to_string(&names).map_err(|source| {
            crate::support::error::Error::Json {
                path: "<union expression>".into(),
                source,
            }
        })?)?;
        selected.push(format!(
            "(prefix {prefix} (builtins.intersectAttrs (builtins.fromJSON {names}) ((builtins.getFlake {flake}).legacyPackages.{system}.ciSets.all)))"
        ));
    }
    Ok(format!(
        "let prefix = p: jobs: builtins.listToAttrs (map (name: {{ name = p + \"::\" + name; value = jobs.${{name}}; }}) (builtins.attrNames jobs)); in {}\n",
        selected.join(" // ")
    ))
}

/// Realise and push what `--copy-to` misses. `--keep-going` so one broken
/// dependency does not block the rest, and `nix copy` skips what the cache
/// already has, so this is a no-op once warm. Push failures warn rather than
/// fail: the cache is an accelerator, not a build product.
fn push_build_deps(key: &SigningKey, drvs: &[String]) -> Result<()> {
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
    let copied = crate::support::nix::Invocation::plain("copy")
        .args(["--to", &key.store()])
        .operands(outputs)
        .status()?;
    if !copied.is_success() {
        crate::support::ui::warning("build-dep push failed (non-fatal)");
    }
    Ok(())
}

/// The nix-fast-build invocation `build_union` runs, kept separate so the
/// flag set reads as one unit.
fn fast_build(
    result_file: &Path,
    request: &UnionRequest<'_>,
    key: Option<&SigningKey>,
) -> Result<crate::support::nix::Invocation> {
    let mut invocation = crate::support::nix::Invocation::tool("nix-fast-build")
        .accepts_flake_config()
        .arg("--skip-cached")
        .args(["--retries", "3"])
        .args(["--no-nom", "--no-link"])
        .args(["--max-jobs", &request.max_jobs.to_string()])
        .args(["--eval-workers", &request.eval_workers.to_string()])
        .args([
            "--eval-max-memory-size",
            &request.eval_memory.to_string(),
        ])
        .args(["--result-file", &result_file.to_string_lossy()])
        .args(["--result-format", "junit"])
        .route(request.route)?;
    if let Some(key) = key {
        invocation = invocation.args(["--copy-to", &key.store()]);
    }
    Ok(invocation)
}

#[cfg(unix)]
fn kill_group(child: &std::process::Child) {
    crate::support::process::signal_group(child.id(), 15);
}

/// Build every case's selected jobs as one prefixed union, streaming results
/// to `on_event` as they arrive. The child gets its own process group, so a
/// timeout or stream error takes its whole nix tree down with it.
pub fn build_union(
    request: UnionRequest<'_>,
    on_event: &mut dyn FnMut(StreamEvent) -> Result<()>,
) -> Result<CommandStatus> {
    crate::support::fs::create_dir_all(request.work_dir)?;
    if let Some(parent) = request.result_file.parent() {
        crate::support::fs::create_dir_all(parent)?;
    }
    // nix-fast-build runs with work_dir as its cwd, so a relative --file or
    // --result-file resolves against that cwd and doubles. Hand it absolute
    // paths; the parent still reaches the same files through its own paths.
    let work_dir =
        std::path::absolute(request.work_dir).map_err(|error| io(request.work_dir, error))?;
    let result_file = std::path::absolute(&request.result_file)
        .map_err(|error| io(&request.result_file, error))?;
    let expression = work_dir.join("build-union.nix");
    crate::support::fs::write(&expression, union_expression(&request.cases)?.as_bytes())?;
    let key = if request.push {
        SigningKey::take()?
    } else {
        None
    };
    let mut needed = Vec::new();
    if key.is_some() {
        for case in &request.cases {
            needed.extend(needed_builds_for(&case.jobs_file, &case.jobs)?);
        }
        needed.sort();
        needed.dedup();
    }

    let mut cmd = fast_build(&result_file, &request, key.as_ref())?
        .args(["--file", &expression.to_string_lossy()])
        .arg("--impure")
        .arg("--stream-json-lines")
        .workdir(&work_dir)
        .command()?;
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    crate::support::tools::log(&cmd);
    let mut child =
        crate::support::tools::spawn(cmd.stdout(Stdio::piped()).stderr(Stdio::piped()))?;
    let stdout = child.stdout.take().expect("stdout was piped");
    let stderr = child.stderr.take().expect("stderr was piped");
    let log_path = work_dir.join("build-union.log");
    let stream_path = work_dir.join("build-results.jsonl");
    let (sender, receiver) = mpsc::channel();
    let stdout_sender = sender.clone();
    // Bytes, not utf8 lines: one stray byte from a compiler must not end the
    // tee and truncate the log the failure report renders from.
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
    let mut log = std::fs::File::create(&log_path).map_err(|e| io(&log_path, e))?;
    let mut stream = std::fs::File::create(&stream_path).map_err(|e| io(&stream_path, e))?;
    let started = std::time::Instant::now();
    let mut stream_error = None;
    let mut fail = |child: &mut std::process::Child,
                    error: crate::support::error::Error|
     -> Result<std::process::ExitStatus> {
        stream_error = Some(error);
        #[cfg(unix)]
        kill_group(child);
        child.wait().map_err(|e| io(&log_path, e))
    };
    let status = loop {
        match receiver.recv_timeout(Duration::from_secs(10)) {
            Ok((true, line)) => {
                writeln!(stream, "{line}").map_err(|e| io(&stream_path, e))?;
                let event = serde_json::from_str(&line)
                    .map_err(|source| crate::support::error::Error::Json {
                        path: stream_path.clone(),
                        source,
                    })
                    .map(StreamEvent::Result)
                    .and_then(&mut *on_event);
                if let Err(error) = event {
                    break fail(&mut child, error)?;
                }
            }
            Ok((false, line)) => {
                writeln!(log, "{line}").map_err(|e| io(&log_path, e))?;
                if let Err(error) = on_event(StreamEvent::Output(line.clone())) {
                    break fail(&mut child, error)?;
                }
                if terminal_renderer_error(&line) {
                    if let Some(status) = child.try_wait().map_err(|e| io(&log_path, e))? {
                        break status;
                    }
                    #[cfg(unix)]
                    kill_group(&child);
                    break child.wait().map_err(|e| io(&log_path, e))?;
                }
                if !renderer_heartbeat(&line) {
                    if let Err(error) = on_event(StreamEvent::Activity) {
                        break fail(&mut child, error)?;
                    }
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if let Err(error) = on_event(StreamEvent::Heartbeat) {
                    break fail(&mut child, error)?;
                }
                if request
                    .hard_timeout
                    .is_some_and(|timeout| started.elapsed() >= timeout)
                {
                    #[cfg(unix)]
                    kill_group(&child);
                    break child.wait().map_err(|e| io(&log_path, e))?;
                }
                if let Some(status) = child.try_wait().map_err(|e| io(&log_path, e))? {
                    break status;
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                break child.wait().map_err(|e| io(&log_path, e))?
            }
        }
    };
    drop(receiver);
    let _ = stdout_thread.join();
    let _ = stderr_thread.join();
    if let Some(error) = stream_error {
        return Err(error);
    }
    let status = CommandStatus::from_exit(status);
    if let Some(key) = &key {
        push_build_deps(key, &needed)?;
    }
    Ok(status)
}
