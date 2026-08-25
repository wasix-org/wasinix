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
use super::{DependencyPath, Failure, FailureCause, LogRef, drv_name};

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
    let stdout = String::from_utf8_lossy(&output.stdout);
    let outputs: Vec<_> = stdout.split_whitespace().map(Path::new).collect();
    output.status.is_success() && !outputs.is_empty() && outputs.iter().all(|path| path.exists())
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
    pub message: Option<String>,
    pub jobs: Vec<String>,
}

#[derive(Debug, Default)]
pub struct DependencyCauses {
    pub roots: Vec<RootCause>,
    pub paths: Vec<DependencyPath>,
    pub untraced_jobs: Vec<crate::support::atoms::JobAddr>,
    pub error: Option<String>,
}

fn derivation_graph(value: &serde_json::Value) -> Result<BTreeMap<String, Vec<String>>> {
    if value.get("version").and_then(serde_json::Value::as_u64) != Some(4) {
        return Err(crate::support::error::Error::Failure(
            "derivation graph is not Nix JSON version 4".into(),
        ));
    }
    let entries = value
        .get("derivations")
        .and_then(serde_json::Value::as_object)
        .ok_or_else(|| {
            crate::support::error::Error::Failure(
                "derivation graph has no derivations object".into(),
            )
        })?;
    let mut graph = BTreeMap::new();
    for (drv, value) in entries {
        let inputs = value
            .get("inputs")
            .and_then(|inputs| inputs.get("drvs"))
            .and_then(serde_json::Value::as_object)
            .ok_or_else(|| {
                crate::support::error::Error::Failure(format!(
                    "derivation graph entry {drv} has no inputs.drvs object"
                ))
            })?;
        let path = format!("/nix/store/{drv}");
        graph.insert(
            path,
            inputs
                .keys()
                .map(|dependency| format!("/nix/store/{dependency}"))
                .collect(),
        );
    }
    Ok(graph)
}

fn shortest_paths(
    graph: &BTreeMap<String, Vec<String>>,
    start: &str,
) -> BTreeMap<String, Option<String>> {
    let mut queue = std::collections::VecDeque::from([start.to_string()]);
    let mut previous: BTreeMap<String, Option<String>> =
        BTreeMap::from([(start.to_string(), None)]);
    while let Some(current) = queue.pop_front() {
        for dependency in graph.get(&current).into_iter().flatten() {
            if !previous.contains_key(dependency) {
                previous.insert(dependency.clone(), Some(current.clone()));
                queue.push_back(dependency.clone());
            }
        }
    }
    previous
}

fn path_to(previous: &BTreeMap<String, Option<String>>, target: &str) -> Option<Vec<String>> {
    let mut path = Vec::new();
    let mut at = Some(target.to_string());
    while let Some(node) = at {
        at = previous.get(&node)?.clone();
        path.push(node);
    }
    path.reverse();
    Some(path)
}

fn reported_root(reported: &crate::nix::buildset::BuilderFailure) -> RootCause {
    let mut message = reported.reason.clone();
    if let Some(last) = reported.log.last() {
        message.push_str(&format!(": {last}"));
    }
    RootCause {
        drv: reported.drv.clone(),
        name: drv_name(&reported.drv),
        log: reported.log.join("\n"),
        message: Some(message),
        jobs: Vec::new(),
    }
}

fn sorted_roots(roots: BTreeMap<String, RootCause>) -> Vec<RootCause> {
    let mut roots: Vec<_> = roots.into_values().collect();
    roots.sort_by(|a, b| a.name.cmp(&b.name));
    roots
}

pub fn dependency_causes(
    failed: &[Case],
    index: &BTreeMap<String, Job>,
    cutoff: std::time::SystemTime,
    builder_failures: &[crate::nix::buildset::BuilderFailure],
) -> DependencyCauses {
    let job_drvs: BTreeSet<&str> = failed
        .iter()
        .filter_map(|case| index.get(&case.attr).map(|job| job.drv.as_str()))
        .collect();
    let mut roots: BTreeMap<String, RootCause> = builder_failures
        .iter()
        .filter(|reported| !job_drvs.contains(reported.drv.as_str()))
        .map(|reported| (reported.drv.clone(), reported_root(reported)))
        .collect();
    let transitive: Vec<(&Case, &Job)> = failed
        .iter()
        .filter(|case| case.transitive)
        .filter_map(|case| index.get(&case.attr).map(|job| (case, job)))
        .collect();
    if transitive.is_empty() {
        return DependencyCauses {
            roots: sorted_roots(roots),
            ..DependencyCauses::default()
        };
    }
    let starts: Vec<String> = transitive.iter().map(|(_, job)| job.drv.clone()).collect();
    let graph = crate::support::nix::Invocation::plain("derivation show")
        .arg("--recursive")
        .local_only()
        .operands(starts)
        .run_json("reading failed derivation graph")
        .and_then(|value| derivation_graph(&value));
    let graph = match graph {
        Ok(graph) => graph,
        Err(error) => {
            let message = crate::support::error::brief(&error, 240);
            crate::support::ui::warning(format!("dependency paths unavailable: {message}"));
            return DependencyCauses {
                roots: sorted_roots(roots),
                untraced_jobs: transitive
                    .into_iter()
                    .map(|(case, _)| crate::support::atoms::JobAddr(case.attr.clone()))
                    .collect(),
                error: Some(message),
                ..DependencyCauses::default()
            };
        }
    };
    for drv in graph.keys() {
        if job_drvs.contains(drv.as_str()) {
            continue;
        }
        if let Some(log) = local_log(drv, cutoff) {
            if !outputs_valid(drv) {
                roots
                    .entry(drv.clone())
                    .and_modify(|root| {
                        if !log.is_empty() {
                            root.log.clone_from(&log);
                        }
                    })
                    .or_insert_with(|| RootCause {
                        drv: drv.clone(),
                        name: drv_name(drv),
                        log,
                        message: None,
                        jobs: Vec::new(),
                    });
            }
        }
    }
    let mut paths = Vec::new();
    let mut untraced_jobs = Vec::new();
    for (case, job) in transitive {
        let mut traced = false;
        let previous = shortest_paths(&graph, &job.drv);
        for root in roots.values_mut() {
            let Some(path) = path_to(&previous, &root.drv) else {
                continue;
            };
            traced = true;
            root.jobs.push(case.attr.clone());
            paths.push(DependencyPath {
                job: crate::support::atoms::JobAddr(case.attr.clone()),
                root: crate::support::atoms::JobAddr(root.name.clone()),
                via: path[1..path.len() - 1]
                    .iter()
                    .map(|drv| drv_name(drv))
                    .collect(),
            });
        }
        if !traced {
            untraced_jobs.push(crate::support::atoms::JobAddr(case.attr.clone()));
        }
    }
    let roots = sorted_roots(roots);
    paths.sort_by(|a, b| (&a.job, &a.root).cmp(&(&b.job, &b.root)));
    DependencyCauses {
        roots,
        paths,
        untraced_jobs,
        error: None,
    }
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
        if cause.log.is_empty() {
            continue;
        }
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
    let mut components = Path::new(&log.path).components();
    if !matches!(components.next(), Some(std::path::Component::Normal(_)))
        || components.next().is_some()
    {
        return crate::support::error::request_error(format!(
            "invalid archived log path {:?}",
            log.path
        ));
    }
    let path = logs_dir.join(&log.path);
    let file = std::fs::File::open(&path).map_err(|e| io(&path, e))?;
    let mut text = String::new();
    flate2::read::GzDecoder::new(file)
        .read_to_string(&mut text)
        .map_err(|e| io(&path, e))?;
    Ok(crate::support::tools::utf8_suffix(&text, limit).to_string())
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::{dependency_causes, derivation_graph, path_to, shortest_paths};

    #[test]
    fn derivation_graph_preserves_branches_and_shortest_paths() {
        let graph = derivation_graph(&json!({
            "version": 4,
            "derivations": {
                "00-selected.drv": {
                    "inputs": { "drvs": {
                        "01-left.drv": {},
                        "02-right.drv": {}
                    }}
                },
                "01-left.drv": {
                    "inputs": { "drvs": { "03-middle.drv": {} }}
                },
                "02-right.drv": {
                    "inputs": { "drvs": { "04-root.drv": {} }}
                },
                "03-middle.drv": {
                    "inputs": { "drvs": { "04-root.drv": {} }}
                },
                "04-root.drv": {
                    "inputs": { "drvs": {} }
                }
            }
        }))
        .unwrap();
        assert_eq!(
            path_to(
                &shortest_paths(&graph, "/nix/store/00-selected.drv"),
                "/nix/store/04-root.drv",
            )
            .unwrap(),
            vec![
                "/nix/store/00-selected.drv",
                "/nix/store/02-right.drv",
                "/nix/store/04-root.drv"
            ]
        );
    }

    #[test]
    fn derivation_graph_rejects_schema_drift() {
        let error = derivation_graph(&json!({
            "version": 4,
            "derivations": {
                "00-selected.drv": { "inputs": {} }
            }
        }))
        .unwrap_err()
        .to_string();
        assert!(error.contains("inputs.drvs"), "{error}");
    }

    #[test]
    fn builder_roots_survive_without_a_traceable_selected_job() {
        let causes = dependency_causes(
            &[],
            &Default::default(),
            std::time::SystemTime::now(),
            &[crate::nix::buildset::BuilderFailure {
                drv: "/nix/store/00-openssl.drv".into(),
                reason: "builder failed with exit code 1".into(),
                log: vec!["configure failed".into()],
            }],
        );
        assert_eq!(causes.roots.len(), 1);
        assert_eq!(causes.roots[0].name, "openssl");
    }
}
