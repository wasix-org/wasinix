//! The facts a build leaves behind, produced once at ingestion and consumed
//! by every renderer: the terminal summary, `run failures`, the markdown
//! report, and the check summary all describe the same [`Failure`] values, so
//! they cannot tell different stories.

pub mod junit;
pub mod logs;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::ci::evalmap::JobInfo;
use crate::support::atoms::{Bytes, DurationSecs, JobAddr};
use crate::support::error::Result;

pub const NO_BUILD_LOG: &str = "build failed before producing a log";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FailureCause {
    /// The job's own build ran and failed; its log explains it.
    Direct,
    /// A non-job derivation in the closure failed; the jobs list its victims.
    Dependency,
    /// The job never ran because something below it failed first.
    Transitive,
}

impl std::fmt::Display for FailureCause {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(match self {
            FailureCause::Direct => "direct",
            FailureCause::Dependency => "dependency",
            FailureCause::Transitive => "transitive",
        })
    }
}

/// Where a failure's archived log lives, relative to the task's log
/// directory. Carried on the failure itself so no renderer has to know the
/// archive layout.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LogRef {
    pub path: String,
    pub bytes: Bytes,
    pub archived_bytes: Bytes,
    pub truncated: bool,
}

/// One failure, fully described.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Failure {
    pub job: JobAddr,
    pub cause: FailureCause,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    /// For a dependency root cause: the jobs it took down.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub jobs: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log: Option<LogRef>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TestOutcome {
    Pass,
    Xfail,
    Broken,
    Fail,
    Xpass,
    Skipped,
}

impl TestOutcome {
    pub fn as_str(self) -> &'static str {
        match self {
            TestOutcome::Pass => "pass",
            TestOutcome::Xfail => "xfail",
            TestOutcome::Broken => "broken",
            TestOutcome::Fail => "fail",
            TestOutcome::Xpass => "xpass",
            TestOutcome::Skipped => "skipped",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TestResult {
    pub job: JobAddr,
    pub outcome: TestOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub test_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub test_family: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    pub duration_seconds: DurationSecs,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub position: Option<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildMetrics {
    /// Sum of top-level build wall times. Builds run concurrently, so this is
    /// useful for relative cost, not the elapsed duration of the CI task.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub build_seconds: BTreeMap<JobAddr, f64>,
    /// The same wall times keyed by derivation, so a fold over many tasks
    /// can count a build once however many job addresses and cases share
    /// it. A case without a recorded derivation (an older junit) keys by
    /// its address, degrading to the per-address count.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub build_seconds_by_drv: BTreeMap<String, f64>,
}

impl BuildMetrics {
    pub fn from_cases(cases: &[junit::Case]) -> BuildMetrics {
        let mut build_seconds: BTreeMap<JobAddr, f64> = BTreeMap::new();
        let mut build_seconds_by_drv: BTreeMap<String, f64> = BTreeMap::new();
        for case in cases
            .iter()
            .filter(|case| case.class == "Build" && case.duration > 0.0)
        {
            *build_seconds.entry(JobAddr(case.attr.clone())).or_default() += case.duration;
            build_seconds_by_drv
                .entry(case.drv.clone().unwrap_or_else(|| case.attr.clone()))
                .or_insert(case.duration);
        }
        BuildMetrics {
            build_seconds,
            build_seconds_by_drv,
        }
    }
}

pub fn metrics(paths: &[PathBuf]) -> BuildMetrics {
    junit::parse_junits(paths, false)
        .map(|cases| BuildMetrics::from_cases(&cases))
        .unwrap_or_default()
}

/// Everything one build task's junit and logs establish.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildFacts {
    /// Whether any junit existed at all: absent results are a crashed or
    /// cancelled build, never a clean one.
    pub complete: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failures: Vec<Failure>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tests: Vec<TestResult>,
    /// Per class (Build, Eval, ...): (total, failed).
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub counts: BTreeMap<String, (usize, usize)>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub build_seconds: BTreeMap<JobAddr, f64>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub build_seconds_by_drv: BTreeMap<String, f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub census: Option<JobCensus>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub union_error: Option<String>,
}

/// Where a build task's selected jobs went, in job addresses. The plan half
/// is the dry run's prediction, taken before anything ran; the outcome half
/// is what happened. They differ when a substituter drops out or a failure
/// blocks its dependents, so merging them would hide the case worth seeing.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobCensus {
    pub selected: usize,
    /// Answered by a reused baseline, so never part of this run's build.
    pub reused: usize,
    pub to_build: usize,
    pub to_fetch: usize,
    pub present: usize,
    pub built: usize,
    pub failed: usize,
    /// Never ran: something below them failed first.
    pub blocked: usize,
}

impl JobCensus {
    /// The parts worth printing, in the order a reader asks about them.
    pub fn parts(&self) -> Vec<String> {
        let mut parts = vec![format!("{} selected", self.selected)];
        for (count, label) in [
            (self.built, "built"),
            (self.to_fetch, "fetched"),
            (self.present, "already present"),
            (self.reused, "reused"),
            (self.failed, "failed"),
            (self.blocked, "blocked"),
        ] {
            if count > 0 {
                parts.push(format!("{count} {label}"));
            }
        }
        parts
    }
}

fn test_results(cases: &[junit::Case]) -> Vec<TestResult> {
    cases
        .iter()
        .filter(|case| case.class == "Build" && (case.is_test || case.expectation.is_some()))
        .map(|case| TestResult {
            job: JobAddr(case.attr.clone()),
            outcome: junit::test_outcome(case),
            test_name: case.test_name.clone(),
            test_family: case.test_family.clone(),
            reason: case.expectation.as_ref().map(|value| value.reason.clone()),
            duration_seconds: DurationSecs(case.duration),
            position: case.position.clone(),
        })
        .collect()
}

/// The readable half of a store path: `…-wasmer-package-tar.drv` is
/// `wasmer-package-tar`.
fn drv_name(drv: &str) -> String {
    drv.rsplit('/')
        .next()
        .and_then(|base| base.split_once('-'))
        .map(|(_, rest)| rest.trim_end_matches(".drv").to_string())
        .unwrap_or_else(|| drv.to_string())
}

fn failures_of(failed: &[junit::Case], roots: &[logs::RootCause]) -> Vec<Failure> {
    let mut failures: Vec<Failure> = failed
        .iter()
        .map(|case| Failure {
            job: JobAddr(case.attr.clone()),
            cause: if case.transitive {
                FailureCause::Transitive
            } else {
                FailureCause::Direct
            },
            class: Some(case.class.clone()),
            message: case.message.clone(),
            jobs: Vec::new(),
            position: case.position.clone(),
            log: None,
        })
        .collect();
    failures.extend(roots.iter().map(|root| {
        let mut jobs = root.jobs.clone();
        jobs.sort();
        jobs.dedup();
        Failure {
            job: JobAddr(root.name.clone()),
            cause: FailureCause::Dependency,
            class: None,
            message: None,
            jobs: jobs.into_iter().map(JobAddr).collect(),
            position: None,
            log: None,
        }
    }));
    failures
}

/// Ingest one build task's junit files against its jobs index: classify each
/// failure, find dependency root causes, archive their logs, and return the
/// facts every renderer shares.
#[allow(clippy::too_many_arguments)]
pub fn ingest(
    junits: &[PathBuf],
    jobs_index: Option<&Path>,
    info: &BTreeMap<JobAddr, JobInfo>,
    cutoff: std::time::SystemTime,
    logs_dir: &Path,
    builder_failures: &[crate::nix::buildset::BuilderFailure],
) -> Result<BuildFacts> {
    let Some(mut cases) = junit::parse_junits(junits, true) else {
        return Ok(BuildFacts::default());
    };
    let index = logs::load_jobs(jobs_index, info);
    let counts = logs::classify(&mut cases, &index, cutoff);
    let failed: Vec<junit::Case> = cases
        .iter()
        .filter(|case| case.message.is_some())
        .cloned()
        .collect();
    let roots = logs::dependency_root_causes(&failed, &index, cutoff);
    let mut failures = failures_of(&failed, &roots);
    // The realise output already named what failed and why. The walk above
    // finds the same thing by querying the store and probing the log
    // directory, which answers nothing when either is unreadable, and then
    // a blocked job's report says only "build failed before producing a
    // log".
    let claimed: std::collections::BTreeSet<&str> =
        roots.iter().map(|root| root.drv.as_str()).collect();
    let job_drvs: std::collections::BTreeSet<&str> =
        index.values().map(|job| job.drv.as_str()).collect();
    for reported in builder_failures {
        if claimed.contains(reported.drv.as_str()) || job_drvs.contains(reported.drv.as_str()) {
            continue;
        }
        let mut message = reported.reason.clone();
        if let Some(last) = reported.log.last() {
            message.push_str(&format!(": {last}"));
        }
        failures.push(Failure {
            job: JobAddr(drv_name(&reported.drv)),
            cause: FailureCause::Dependency,
            class: None,
            message: Some(message),
            jobs: Vec::new(),
            position: None,
            log: None,
        });
    }
    logs::archive(logs_dir, &failed, &roots, &index, &mut failures)?;
    let metrics = BuildMetrics::from_cases(&cases);
    Ok(BuildFacts {
        complete: true,
        failures,
        tests: test_results(&cases),
        counts,
        build_seconds: metrics.build_seconds,
        build_seconds_by_drv: metrics.build_seconds_by_drv,
        census: None,
        union_error: None,
    })
}
