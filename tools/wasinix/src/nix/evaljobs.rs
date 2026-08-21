//! Running nix-eval-jobs and parsing its JSON-lines format, in exactly one
//! place.

use std::io::Write;
use std::path::Path;

use serde::Deserialize;

use crate::nix::route::Route;
use crate::support::error::{Error, Result, io};

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalJob {
    #[serde(default)]
    pub attr_path: Vec<String>,
    #[serde(default)]
    pub drv_path: Option<String>,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub needed_builds: Vec<String>,
    #[serde(default)]
    pub cache_status: Option<String>,
    #[serde(default)]
    pub outputs: std::collections::BTreeMap<String, String>,
    #[serde(default)]
    pub meta: Meta,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct Meta {
    #[serde(default)]
    pub position: Option<String>,
}

impl EvalJob {
    pub fn name(&self) -> String {
        self.attr_path.join(".")
    }
}

pub fn parse_line(line: &str) -> Result<EvalJob> {
    serde_json::from_str(line).map_err(|source| Error::Json {
        path: "<nix-eval-jobs line>".into(),
        source,
    })
}

/// Every job in a JSON-lines file; a malformed line fails the read, since a
/// truncated index silently shrinking a job set is how builds go missing.
pub fn parse_file(text: &str) -> Result<Vec<EvalJob>> {
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .map(parse_line)
        .collect()
}

pub struct RunRequest<'a> {
    pub workdir: &'a Path,
    pub flake: &'a str,
    pub jobs_path: &'a Path,
    pub stderr_log: &'a Path,
    pub offline: bool,
    /// Query the binary cache for each job's status. A per-job network round
    /// trip over thousands of jobs, so it is only worth it when a caller
    /// reads the status (the build's push list); warming inputs does not.
    pub check_cache: bool,
    pub route: &'a Route,
}

/// Run nix-eval-jobs into `jobs_path`, teeing its diagnostics to `stderr_log`.
/// A top-level evaluation failure is returned as text rather than raised: it
/// is report content, and the caller decides what it fails.
pub fn run(request: &RunRequest<'_>) -> Result<Option<String>> {
    let limits = request.route.limits()?;
    let timeout = limits.timeout;
    // The workers race to fetch a workdir flake: the first records its final
    // narHash while another may still re-fetch the locked rev through the
    // archive path, and the two disagree on a tree carrying a submodule
    // gitlink. One prefetch settles the fetch before any worker starts.
    if request.flake.starts_with('.') {
        crate::support::nix::Invocation::plain("flake prefetch")
            .accepts_flake_config()
            .workdir(request.workdir)
            .checked_output("prefetching the case worktree")?;
    }
    // nix-eval-jobs comes from PATH so a run does not fetch the registry's
    // channel tarball. meta.position anchors failure annotations at the
    // package definition.
    let mut invocation = crate::support::nix::Invocation::tool("nix-eval-jobs")
        .accepts_flake_config()
        .args(["--flake", request.flake, "--meta"])
        .args(["--workers", &limits.workers.to_string()])
        .args(["--max-memory-size", &limits.memory.to_string()])
        .workdir(request.workdir)
        .timeout(timeout)
        .route(request.route)?;
    if request.check_cache {
        invocation = invocation.arg("--check-cache-status");
    }
    if request.offline {
        invocation = invocation.option("offline", "true");
    }
    for path in [request.jobs_path, request.stderr_log] {
        if let Some(parent) = path.parent() {
            crate::support::fs::create_dir_all(parent)?;
        }
    }
    let mut jobs_file =
        std::fs::File::create(request.jobs_path).map_err(|e| io(request.jobs_path, e))?;
    let stderr_log = crate::support::log::BoundedLog::create(request.stderr_log)?;
    let completion = invocation.run_piped(
        |mut stdout| {
            std::io::copy(&mut stdout, &mut jobs_file)
                .map_err(|error| io(request.jobs_path, error))?;
            jobs_file
                .flush()
                .map_err(|error| io(request.jobs_path, error))
        },
        |mut stderr| {
            let mut log = stderr_log;
            std::io::copy(&mut stderr, &mut log)
                .map_err(|error| io(request.stderr_log, error))?;
            log.finish()?;
            Ok(())
        },
    )?;
    let timed_out = matches!(completion, crate::support::tools::Completion::TimedOut(_));
    let output = completion.value();
    if timed_out {
        return Ok(Some(format!(
            "evaluation timed out after {} seconds",
            timeout.as_secs()
        )));
    }
    if output.status.success() {
        return Ok(None);
    }
    let stderr = crate::support::fs::tail(request.stderr_log, 256 * 1024)?;
    Ok(Some(error_excerpt(&stderr)))
}

/// A nix trace ends with its root cause on an indented `error:` line; the
/// unindented `error: worker error:` opener above it is only the trace
/// preamble.
pub fn error_excerpt(stderr: &str) -> String {
    let lines: Vec<&str> = stderr.lines().collect();
    let start = lines
        .iter()
        .rposition(|line| line.trim_start().starts_with("error:"))
        .unwrap_or(lines.len().saturating_sub(30));
    lines[start..]
        .iter()
        .take(60)
        .cloned()
        .collect::<Vec<_>>()
        .join("\n")
        .trim_start()
        .to_string()
}
