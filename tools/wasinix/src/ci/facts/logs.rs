//! Which derivation actually failed, and archiving its log so a reader can
//! reach it from the report. A failed job with a fresh log ran and failed
//! itself; one without never ran, because a dependency failed first, and
//! telling those apart keeps a toolchain break readable.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::Path;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::ci::evalmap::JobInfo;
use crate::support::atoms::Bytes;
use crate::support::error::{Result, io};
use crate::support::schema::Document;

use super::junit::Case;
use super::{Failure, FailureCause, LogRef};

const MAX_ARCHIVED_LOG_BYTES: usize = 20 * 1024 * 1024;
const MAX_ARCHIVED_TASK_BYTES: usize = 100 * 1024 * 1024;
const LOG_ROOT: &str = "/nix/var/log/nix/drvs";

/// One evaluated job as nix-eval-jobs described it.
#[derive(Debug, Clone, Default)]
pub struct Job {
    pub drv: String,
    pub position: Option<String>,
    pub expectation: Option<crate::ci::evalmap::TestExpectation>,
    pub is_test: bool,
    pub test_name: Option<String>,
    pub test_family: Option<String>,
}

/// The nix-eval-jobs JSON-lines index for a task's jobs.
pub fn load_jobs(
    path: Option<&Path>,
    info: &BTreeMap<crate::support::atoms::JobAddr, JobInfo>,
) -> BTreeMap<String, Job> {
    let mut index = BTreeMap::new();
    let Some(path) = path else { return index };
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) => {
            crate::support::ui::warning(format!("no jobs index ({error})"));
            return index;
        }
    };
    let jobs = match crate::nix::evaljobs::parse_file(&text) {
        Ok(jobs) => jobs,
        Err(error) => {
            crate::support::ui::warning(format!("unreadable jobs index ({error})"));
            return index;
        }
    };
    for job in jobs {
        if job.error.is_some() {
            continue;
        }
        let name = job.name();
        index.insert(
            name.clone(),
            Job {
                drv: job.drv_path.unwrap_or_default(),
                position: job.meta.position,
                expectation: info
                    .get(name.as_str())
                    .and_then(|job| job.test_expectation.clone()),
                is_test: info
                    .get(name.as_str())
                    .is_some_and(|job| job.role.as_deref() == Some("check")),
                test_name: info
                    .get(name.as_str())
                    .and_then(|job| job.test_name.clone()),
                test_family: info
                    .get(name.as_str())
                    .and_then(|job| job.test_family.clone()),
            },
        );
    }
    index
}

/// Logs older than the evaluation predate this run on a warm store, and would
/// misreport a stale failure as this run's.
fn fresh(path: &Path, cutoff: std::time::SystemTime) -> bool {
    std::fs::metadata(path)
        .and_then(|meta| meta.modified())
        .map(|modified| modified >= cutoff)
        .unwrap_or(false)
}

/// The build log a derivation left behind, or `None` if it never ran. Probes
/// the log directory rather than asking nix, which would query substituters
/// over the network once per job.
fn local_log(drv: &str, cutoff: std::time::SystemTime) -> Option<String> {
    let base = drv.rsplit('/').next().unwrap_or(drv);
    if base.len() < 2 {
        return None;
    }
    let stem = format!("{LOG_ROOT}/{}/{}", &base[..2], &base[2..]);
    if !["", ".bz2", ".zst"]
        .iter()
        .any(|ext| fresh(Path::new(&format!("{stem}{ext}")), cutoff))
    {
        return None;
    }
    let output = crate::support::nix::Invocation::plain("log")
        .local_only()
        .operand(drv)
        .probe("an unreadable log is still a direct failure")
        .ok()?;
    // A log that exists but cannot be read is still a direct failure.
    Some(if output.status.is_success() {
        String::from_utf8_lossy(&output.stdout).to_string()
    } else {
        String::new()
    })
}

fn outputs_valid(drv: &str) -> bool {
    let Ok(output) = crate::support::nix::Invocation::tool("nix-store")
        .args(["--query", "--outputs"])
        .operand(drv)
        .probe("missing outputs mean invalid, not an error")
    else {
        return false;
    };
    output.status.is_success()
        && String::from_utf8_lossy(&output.stdout)
            .split_whitespace()
            .any(|path| Path::new(path).exists())
}

/// Attach expectations and positions, fetch direct failures' logs, and mark
/// the failures whose derivation never ran as transitive. Returns per-class
/// (total, failed) counts.
pub fn classify(
    cases: &mut [Case],
    index: &BTreeMap<String, Job>,
    cutoff: std::time::SystemTime,
) -> BTreeMap<String, (usize, usize)> {
    let mut counts: BTreeMap<String, (usize, usize)> = BTreeMap::new();
    for case in cases.iter_mut() {
        case.expectation = index
            .get(&case.attr)
            .and_then(|job| job.expectation.clone());
        case.is_test = index.get(&case.attr).is_some_and(|job| job.is_test);
        case.test_name = index.get(&case.attr).and_then(|job| job.test_name.clone());
        case.test_family = index
            .get(&case.attr)
            .and_then(|job| job.test_family.clone());
        case.position = index.get(&case.attr).and_then(|job| job.position.clone());
        let entry = counts.entry(case.class.clone()).or_insert((0, 0));
        entry.0 += 1;
        if case.message.is_some() {
            entry.1 += 1;
            if case.class == "Build" {
                if let Some(job) = index.get(&case.attr) {
                    match local_log(&job.drv, cutoff) {
                        Some(log) => case.log = Some(log),
                        None if case.log.as_deref().is_none_or(str::is_empty) => {
                            case.transitive = true;
                        }
                        None => {}
                    }
                }
            }
        }
    }
    counts
}

#[derive(Debug, Clone)]
pub struct RootCause {
    pub drv: String,
    pub name: String,
    pub log: String,
    pub jobs: Vec<String>,
}

/// Walk the failed jobs' closures for a derivation that ran, failed, and is
/// not itself a job: its log is the one explanation none of the victims carry.
pub fn dependency_root_causes(
    failed: &[Case],
    index: &BTreeMap<String, Job>,
    cutoff: std::time::SystemTime,
) -> Vec<RootCause> {
    let job_drvs: BTreeSet<&str> = failed
        .iter()
        .filter_map(|case| index.get(&case.attr).map(|job| job.drv.as_str()))
        .collect();
    let mut checked: BTreeMap<String, Option<String>> = BTreeMap::new();
    let mut roots: BTreeMap<String, RootCause> = BTreeMap::new();

    for case in failed.iter().filter(|case| case.transitive) {
        let Some(job) = index.get(&case.attr) else {
            continue;
        };
        let Ok(output) = crate::support::nix::Invocation::tool("nix-store")
            .args(["--query", "--requisites"])
            .operand(&job.drv)
            .probe("one unqueryable derivation must not lose the report")
        else {
            continue;
        };
        if !output.status.is_success() {
            crate::support::ui::warning(format!(
                "requisites of {}: {}",
                case.attr,
                output.stderr.trim()
            ));
            continue;
        }
        for drv in String::from_utf8_lossy(&output.stdout).split_whitespace() {
            if !drv.ends_with(".drv") || job_drvs.contains(drv) {
                continue;
            }
            if !checked.contains_key(drv) {
                let mut root = None;
                if let Some(log) = local_log(drv, cutoff) {
                    if !outputs_valid(drv) {
                        let name = drv
                            .rsplit('/')
                            .next()
                            .and_then(|base| base.split_once('-'))
                            .map(|(_, rest)| rest.trim_end_matches(".drv").to_string())
                            .unwrap_or_else(|| drv.to_string());
                        roots.entry(drv.to_string()).or_insert(RootCause {
                            drv: drv.to_string(),
                            name,
                            log,
                            jobs: Vec::new(),
                        });
                        root = Some(drv.to_string());
                    }
                }
                checked.insert(drv.to_string(), root);
            }
            if let Some(Some(key)) = checked.get(drv) {
                if let Some(root) = roots.get_mut(key) {
                    root.jobs.push(case.attr.clone());
                }
            }
        }
    }
    let mut found: Vec<RootCause> = roots.into_values().collect();
    found.sort_by(|a, b| a.name.cmp(&b.name));
    found
}

/// One archived log in the manifest. The same struct writes and reads the
/// manifest, so the two sides cannot drift.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestEntry {
    pub job: String,
    pub drv: String,
    pub cause: FailureCause,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub jobs: Vec<String>,
    pub path: String,
    pub bytes: Bytes,
    pub archived_bytes: Bytes,
    pub truncated: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct LogManifest {
    pub logs: Vec<ManifestEntry>,
}

impl Document for LogManifest {
    const KIND: &'static str = "logManifest";
    const SCHEMA: u32 = 1;
}

/// Archive the tail of every failing derivation's log under `logs_dir` and
/// bind a [`LogRef`] into each matching failure, so every rendering of a
/// failure can reach its log without knowing the directory layout.
pub fn archive(
    logs_dir: &Path,
    failed: &[Case],
    roots: &[RootCause],
    index: &BTreeMap<String, Job>,
    failures: &mut [Failure],
) -> Result<LogManifest> {
    let mut candidates: Vec<(String, String, FailureCause, Vec<String>, &str)> = Vec::new();
    for case in failed.iter().filter(|case| !case.transitive) {
        let (Some(log), Some(job)) = (case.log.as_deref(), index.get(&case.attr)) else {
            continue;
        };
        candidates.push((
            case.attr.clone(),
            job.drv.clone(),
            FailureCause::Direct,
            Vec::new(),
            log,
        ));
    }
    for cause in roots {
        candidates.push((
            cause.name.clone(),
            cause.drv.clone(),
            FailureCause::Dependency,
            cause.jobs.clone(),
            &cause.log,
        ));
    }

    crate::support::fs::create_dir_all(logs_dir)?;
    let mut manifest = LogManifest::default();
    let mut archived = 0usize;
    let mut seen = BTreeSet::new();
    for (job, drv, cause, jobs, log) in candidates {
        if archived >= MAX_ARCHIVED_TASK_BYTES || !seen.insert(drv.clone()) {
            continue;
        }
        let raw = log.as_bytes();
        let limit = MAX_ARCHIVED_LOG_BYTES.min(MAX_ARCHIVED_TASK_BYTES - archived);
        let truncated = raw.len() > limit;
        let kept = &raw[raw.len().saturating_sub(limit)..];
        archived += kept.len();
        let name = format!("{:x}", Sha256::digest(drv.as_bytes()));
        let name = format!("{}.log.gz", &name[..20]);
        let target = logs_dir.join(&name);
        let file = std::fs::File::create(&target).map_err(|e| io(&target, e))?;
        let mut encoder = flate2::write::GzEncoder::new(file, flate2::Compression::new(6));
        encoder.write_all(kept).map_err(|e| io(&target, e))?;
        encoder.finish().map_err(|e| io(&target, e))?;
        let entry = ManifestEntry {
            job: job.clone(),
            drv,
            cause,
            jobs,
            path: name,
            bytes: Bytes(raw.len() as u64),
            archived_bytes: Bytes(kept.len() as u64),
            truncated,
        };
        for failure in failures.iter_mut() {
            if failure.log.is_none() && failure.job.as_str() == job && failure.cause == cause {
                failure.log = Some(LogRef {
                    path: entry.path.clone(),
                    bytes: entry.bytes,
                    archived_bytes: entry.archived_bytes,
                    truncated: entry.truncated,
                });
            }
        }
        manifest.logs.push(entry);
    }
    crate::support::schema::write(&logs_dir.join("manifest.json"), &manifest)?;
    Ok(manifest)
}

/// The gunzipped tail of an archived log, for display.
pub fn read_archived(logs_dir: &Path, log: &LogRef, limit: usize) -> Result<String> {
    use std::io::Read;
    let path = logs_dir.join(&log.path);
    let file = std::fs::File::open(&path).map_err(|e| io(&path, e))?;
    let mut text = String::new();
    flate2::read::GzDecoder::new(file)
        .read_to_string(&mut text)
        .map_err(|e| io(&path, e))?;
    Ok(crate::support::tools::utf8_suffix(&text, limit).to_string())
}
