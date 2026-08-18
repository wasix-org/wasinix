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

}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TestResult {
    pub job: JobAddr,
    pub outcome: TestOutcome,
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
            *build_seconds
                .entry(JobAddr(case.attr.clone()))
                .or_default() += case.duration;
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
}

fn test_results(cases: &[junit::Case]) -> Vec<TestResult> {
    cases
        .iter()
        .filter(|case| case.class == "Build" && (case.is_test || case.expectation.is_some()))
        .map(|case| TestResult {
            job: JobAddr(case.attr.clone()),
            outcome: junit::test_outcome(case),
            reason: case.expectation.as_ref().map(|value| value.reason.clone()),
            duration_seconds: DurationSecs(case.duration),
            position: case.position.clone(),
        })
        .collect()
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
pub fn ingest(
    junits: &[PathBuf],
    jobs_index: Option<&Path>,
    info: &BTreeMap<JobAddr, JobInfo>,
    cutoff: std::time::SystemTime,
    logs_dir: &Path,
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
    logs::archive(logs_dir, &failed, &roots, &index, &mut failures)?;
    let metrics = BuildMetrics::from_cases(&cases);
    Ok(BuildFacts {
        complete: true,
        failures,
        tests: test_results(&cases),
        counts,
        build_seconds: metrics.build_seconds,
        build_seconds_by_drv: metrics.build_seconds_by_drv,
    })
}
