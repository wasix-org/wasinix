//! Running nix-eval-jobs and parsing its JSON-lines format, in exactly one
//! place.

use std::io::{BufRead, BufReader, Write};
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

/// Decode JSON-quoted names and Nix's quoted attr display while preserving
/// names from Wasinix's already-projected JUnit files.
pub(crate) fn attr_name(raw: &str) -> String {
    if raw.starts_with('"') {
        serde_json::from_str(raw).unwrap_or_else(|_| {
            raw.strip_prefix('"')
                .and_then(|name| name.strip_suffix('"'))
                .unwrap_or(raw)
                .to_string()
        })
    } else {
        raw.to_string()
    }
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
    /// Exact catalog addresses to retain. `None` evaluates every job.
    pub selected: Option<&'a [String]>,
    pub job_errors: JobErrors,
    pub route: &'a Route,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum JobErrors {
    Collect,
    FailFast,
}

const SELECT_FILE_FLAG: &str = "--select-file";

pub(crate) fn selection_function(names: &[String]) -> Result<String> {
    let names = serde_json::to_string(names).map_err(|source| Error::Json {
        path: "<CI job selection>".into(),
        source,
    })?;
    let names = serde_json::to_string(&names).map_err(|source| Error::Json {
        path: "<CI job selection>".into(),
        source,
    })?;
    Ok(format!(
        "jobs: let names = builtins.fromJSON {names}; in builtins.listToAttrs (map (name: {{ inherit name; value = jobs.${{name}}; }}) names)"
    ))
}

pub(crate) fn stream_jobs(
    reader: &mut impl BufRead,
    writer: &mut impl Write,
    jobs_path: &Path,
    job_errors: JobErrors,
) -> Result<Option<String>> {
    let mut line = String::new();
    loop {
        line.clear();
        if reader
            .read_line(&mut line)
            .map_err(|error| io(jobs_path, error))?
            == 0
        {
            return Ok(None);
        }
        writer
            .write_all(line.as_bytes())
            .map_err(|error| io(jobs_path, error))?;
        if job_errors == JobErrors::FailFast && !line.trim().is_empty() {
            let job = parse_line(&line)?;
            if let Some(error) = &job.error {
                return Ok(Some(format!("{}: {}", job.name(), error_excerpt(&error))));
            }
        }
    }
}

pub(crate) fn archive_inputs_invocation(workdir: &Path) -> crate::support::nix::Invocation {
    crate::support::nix::Invocation::plain("flake archive")
        .accepts_flake_config()
        .operand("path:.")
        .workdir(workdir)
}

pub(crate) fn evaluator_invocation(workdir: &Path) -> crate::support::nix::Invocation {
    crate::support::nix::Invocation::eval_jobs()
        .accepts_flake_config()
        .arg("--meta")
        // Every worker evaluates independently; a shared SQLite cache only
        // serializes their writes and emits a busy warning for each collision.
        .option("eval-cache", "false")
        .workdir(workdir)
}
/// Run nix-eval-jobs into `jobs_path`, teeing its diagnostics to `stderr_log`.
/// A top-level evaluation failure is returned as text rather than raised: it
/// is report content, and the caller decides what it fails.
pub fn run(request: &RunRequest<'_>) -> Result<Option<String>> {
    let limits = request.route.limits()?;
    let timeout = limits.timeout;
    let gc_roots = request
        .jobs_path
        .parent()
        .unwrap_or(request.workdir)
        .join("gc-roots");
    crate::support::fs::create_dir_all(&gc_roots)?;
    // Fetch the complete locked input graph before workers fan out. Fetching
    // only the root leaves inputs such as Wasmer's submodule checkout racing
    // behind one shared fetch lock across every worker.
    if request.flake.starts_with('.') || request.flake.starts_with("path:.") {
        archive_inputs_invocation(request.workdir)
            .route(request.route)?
            .checked_output("archiving the case inputs")?;
    }
    for path in [request.jobs_path, request.stderr_log] {
        if let Some(parent) = path.parent() {
            crate::support::fs::create_dir_all(parent)?;
        }
    }
    // nix-eval-jobs comes from PATH so a run does not fetch the registry's
    // channel tarball. meta.position anchors failure annotations at the
    // package definition.
    let mut invocation = evaluator_invocation(request.workdir)
        .args(["--flake", request.flake])
        .args(["--gc-roots-dir", &gc_roots.to_string_lossy()])
        .args(["--workers", &limits.workers.to_string()])
        .args(["--max-memory-size", &limits.memory.to_string()])
        .timeout(timeout)
        .route(request.route)?;
    if let Some(selected) = request.selected {
        let selection_path = request.jobs_path.with_extension("selection.nix");
        crate::support::fs::write(&selection_path, selection_function(selected)?.as_bytes())?;
        let selection_path = crate::support::fs::absolute(&selection_path)?;
        invocation = invocation.args([SELECT_FILE_FLAG, &selection_path.to_string_lossy()]);
    }
    if request.check_cache {
        invocation = invocation.arg("--check-cache-status");
    }
    if request.offline {
        invocation = invocation.option("offline", "true");
    }
    let mut jobs_file =
        std::fs::File::create(request.jobs_path).map_err(|e| io(request.jobs_path, e))?;
    let stderr_log = crate::support::log::BoundedLog::create(request.stderr_log)?;
    let mut job_error = None;
    let completion = invocation.run_piped(
        |stdout| {
            job_error = stream_jobs(
                &mut BufReader::new(stdout),
                &mut jobs_file,
                request.jobs_path,
                request.job_errors,
            )?;
            jobs_file
                .flush()
                .map_err(|error| io(request.jobs_path, error))
        },
        |mut stderr| {
            let mut log = stderr_log;
            std::io::copy(&mut stderr, &mut log).map_err(|error| io(request.stderr_log, error))?;
            log.finish()?;
            Ok(())
        },
    )?;
    if let Some(error) = job_error {
        return Ok(Some(error));
    }
    let timed_out = matches!(completion, crate::support::tools::Completion::TimedOut(_));
    let status = completion.value();
    if timed_out {
        return Ok(Some(format!(
            "evaluation timed out after {} seconds",
            timeout.as_secs()
        )));
    }
    if status.success() {
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
