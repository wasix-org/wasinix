//! Compare two cases by stable job name, as a projection of persisted state.
//!
//! This is the product: everything else exists to put two comparable cases in
//! front of it. No task computes it; the fold derives it from the case
//! directories whenever it runs, so each half of the story surfaces the
//! moment its inputs exist. Tasks do work and emit facts; anything
//! computable from persisted facts belongs here.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::ci::evalmap::{EvalMap, StatusMap};
use crate::ci::types::{Build, CaseRef, RevSource};
use crate::support::atoms::{JobAddr, JobStatus};
use crate::support::error::{request_error, Result};
use crate::support::schema::Document;

/// Per-job outcomes as a case directory document.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct JobStatuses {
    pub statuses: StatusMap,
}

impl Document for JobStatuses {
    const KIND: &'static str = "jobStatuses";
    const SCHEMA: u32 = 1;
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VersionUpdate {
    pub subject: String,
    pub before: String,
    pub after: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changelog: Option<String>,
    pub jobs: Vec<JobAddr>,
}

/// Which jobs a case covers: its named jobs plus every job in its sets.
pub fn selected(case: &Build<RevSource>, map: &EvalMap) -> Result<BTreeSet<String>> {
    let mut jobs: BTreeSet<String> = map
        .resolve_enabled_jobs(&case.requested_jobs(), &case.enabled_tags)?
        .into_iter()
        .collect();
    for set in case.requested_sets() {
        if let Some(members) = map.sets.get(set.as_str()) {
            jobs.extend(
                members
                    .iter()
                    .filter(|job| map.tag_enabled(job, &case.enabled_tags))
                    .cloned(),
            );
        }
    }
    Ok(jobs)
}

pub fn selected_case(case: CaseRef<'_, RevSource>, map: &EvalMap) -> Result<BTreeSet<String>> {
    match case {
        CaseRef::Build(case) => selected(case, map),
        CaseRef::Spot(case) => Ok(map.resolve_jobs(&case.targets)?.into_iter().collect()),
    }
}

/// Read per-job status from a case directory: a published baseline carries its
/// status directly, a case built here has junit instead.
pub fn case_status(paths: &Path) -> StatusMap {
    if let Ok(statuses) = crate::support::schema::read::<JobStatuses>(&crate::ci::prepare::status_path(paths)) {
        return statuses.statuses;
    }
    let mut files: Vec<std::path::PathBuf> = std::fs::read_dir(crate::ci::prepare::junit_dir(paths))
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "xml"))
                .collect()
        })
        .unwrap_or_default();
    files.sort();
    junit_status(&files)
}

/// Parse a build's junit. A job is a failure if any run of it failed.
pub fn junit_status(paths: &[std::path::PathBuf]) -> StatusMap {
    use quick_xml::events::Event;
    let mut status = StatusMap::new();
    for path in paths {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(_) => continue,
        };
        let mut reader = quick_xml::Reader::from_str(&text);
        let mut buffer = Vec::new();
        let mut current: Option<String> = None;
        while let Ok(event) = reader.read_event_into(&mut buffer) {
            match event {
                Event::Start(element) | Event::Empty(element) => {
                    match element.name().as_ref() {
                        b"testcase" => {
                            // nix-eval-jobs quotes the dotted attr name, and the
                            // quotes arrive escaped.
                            current = element
                                .attributes()
                                .flatten()
                                .find(|attr| attr.key.as_ref() == b"name")
                                .and_then(|attr| attr.unescape_value().ok())
                                .map(|value| value.trim_matches('"').to_string())
                                .filter(|value| !value.is_empty());
                            if let Some(job) = &current {
                                status
                                    .entry(JobAddr(job.clone()))
                                    .or_insert(JobStatus::Success);
                            }
                        }
                        b"failure" => {
                            if let Some(job) = &current {
                                status.insert(JobAddr(job.clone()), JobStatus::Failure);
                            }
                        }
                        _ => {}
                    }
                }
                Event::End(element) => {
                    if element.name().as_ref() == b"testcase" {
                        current = None;
                    }
                }
                Event::Eof => break,
                _ => {}
            }
            buffer.clear();
        }
    }
    status
}


/// The eval-time half of a comparison: what two evaluations say changed.
/// Computable the moment both maps exist, long before anything builds.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalDiff {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub added: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rebuilt: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub identity_transitions: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub version_updates: Vec<VersionUpdate>,
    /// Jobs erroring in the head evaluation that the base evaluated clean.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub new_eval_errors: Vec<JobAddr>,
    /// Job -> the version it serves, for rendering. Every list here names
    /// jobs; a reader wants to know which version each one is.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub identities: BTreeMap<JobAddr, String>,
    pub selected_count: usize,
}

/// The build-time half: status transitions over the shared coverage.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildDiff {
    /// Jobs both cases cover that stopped passing.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub regressions: Vec<JobAddr>,
    /// Jobs only the candidate covers that fail. They cannot transition, so
    /// without this a newly added broken package reads as green.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub new_failures: Vec<JobAddr>,
    /// Jobs only the baseline covers that were passing when they vanished.
    /// They remain visible for review but do not fail the comparison.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dropped_successes: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fixes: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub existing_failures: Vec<JobAddr>,
    #[serde(default)]
    pub case_failure: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub missing_results: Vec<String>,
}

impl BuildDiff {
    pub fn regression_count(&self) -> usize {
        self.regressions.len()
            + self.new_failures.len()
            + usize::from(self.case_failure)
    }
}

/// One candidate's comparison against the baseline, derived from persisted
/// case state whenever the fold runs; each half is present once its inputs
/// exist. No task computes this.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Comparison {
    pub candidate: String,
    pub base_evaluated: bool,
    pub head_evaluated: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub eval: Option<EvalDiff>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub builds: Option<BuildDiff>,
}

impl Comparison {
    /// Everything that fails the comparison, however the job entered it.
    pub fn regression_count(&self) -> usize {
        self.eval
            .as_ref()
            .map(|eval| eval.new_eval_errors.len())
            .unwrap_or(0)
            + self
                .builds
                .as_ref()
                .map(BuildDiff::regression_count)
                .unwrap_or(0)
    }
}

/// What the two cases cover, shared by both halves.
struct Coverage {
    base: BTreeSet<String>,
    head: BTreeSet<String>,
    both: Vec<String>,
    /// A spot case covers only its own targets, so added/removed carry no
    /// signal and the diff is judged on the shared jobs alone.
    common_only: bool,
}

fn coverage(
    base_case: CaseRef<'_, RevSource>,
    base_map: &EvalMap,
    head_case: CaseRef<'_, RevSource>,
    head_map: &EvalMap,
) -> Result<Coverage> {
    let base = selected_case(base_case, base_map)?;
    let head = selected_case(head_case, head_map)?;
    let both: Vec<String> = base.intersection(&head).cloned().collect();
    let common_only =
        matches!(base_case, CaseRef::Spot(_)) || matches!(head_case, CaseRef::Spot(_));
    if common_only && both.is_empty() {
        return request_error("diff cases have no shared target coverage");
    }
    Ok(Coverage {
        base,
        head,
        both,
        common_only,
    })
}

fn eval_diff(coverage: &Coverage, base_map: &EvalMap, head_map: &EvalMap) -> EvalDiff {
    let added: Vec<JobAddr> = if coverage.common_only {
        Vec::new()
    } else {
        coverage
            .head
            .difference(&coverage.base)
            .cloned()
            .map(JobAddr)
            .collect()
    };
    let removed: Vec<JobAddr> = if coverage.common_only {
        Vec::new()
    } else {
        coverage
            .base
            .difference(&coverage.head)
            .cloned()
            .map(JobAddr)
            .collect()
    };
    let identity_changed: Vec<&String> = coverage
        .both
        .iter()
        .filter(|job| base_map.identity(job) != head_map.identity(job))
        .collect();
    // Keyed by the package's own changelog as well as its subject: two
    // different packages can share a display subject and a version move, and
    // must not merge into one row pointing at whichever changelog won.
    type UpdateKey = (String, String, String, Option<String>);
    let mut version_updates: BTreeMap<UpdateKey, VersionUpdate> = BTreeMap::new();
    for job in &coverage.both {
        let (Some(before), Some(after)) = (base_map.version(job), head_map.version(job)) else {
            continue;
        };
        if before == after {
            continue;
        }
        let info = head_map.info.get(job.as_str());
        let subject = info
            .and_then(|info| info.subject.clone().or_else(|| info.display_name.clone()))
            .unwrap_or_else(|| job.clone());
        let changelog = info.and_then(|info| info.changelog.clone());
        let update = version_updates
            .entry((
                subject.clone(),
                before.clone(),
                after.clone(),
                changelog.clone(),
            ))
            .or_insert_with(|| VersionUpdate {
                subject,
                before,
                after,
                changelog,
                jobs: Vec::new(),
            });
        update.jobs.push(JobAddr(job.clone()));
    }
    EvalDiff {
        rebuilt: coverage
            .both
            .iter()
            .filter(|job| {
                base_map.jobs.get(job.as_str()) != head_map.jobs.get(job.as_str())
                    && head_map.rebuild_signal(job)
            })
            .map(|job| JobAddr(job.clone()))
            .collect(),
        identity_transitions: identity_changed
            .iter()
            .map(|job| {
                format!(
                    "{job}: {} -> {}",
                    base_map.identity(job).unwrap_or_else(|| "?".into()),
                    head_map.identity(job).unwrap_or_else(|| "?".into())
                )
            })
            .collect(),
        version_updates: version_updates.into_values().collect(),
        new_eval_errors: coverage
            .both
            .iter()
            .filter(|job| {
                head_map.errors.contains_key(job.as_str())
                    && !base_map.errors.contains_key(job.as_str())
            })
            .map(|job| JobAddr(job.clone()))
            .collect(),
        selected_count: if coverage.common_only {
            coverage.both.len()
        } else {
            coverage.base.union(&coverage.head).count()
        },
        // A removed job has no head identity, so the base is the only side
        // that can say which version went away.
        identities: if coverage.common_only {
            coverage.both.iter().cloned().collect::<BTreeSet<_>>()
        } else {
            coverage.base.union(&coverage.head).cloned().collect()
        }
        .iter()
        .filter_map(|job| {
            head_map
                .identity(job)
                .or_else(|| base_map.identity(job))
                .map(|identity| (JobAddr(job.clone()), identity))
        })
        .collect(),
        added,
        removed,
    }
}

fn build_diff(
    coverage: &Coverage,
    eval: &EvalDiff,
    head_map: &EvalMap,
    base_status: &StatusMap,
    head_status: &StatusMap,
) -> BuildDiff {
    let head_aliases: BTreeSet<&str> = coverage
        .head
        .iter()
        .filter_map(|job| head_map.info.get(job.as_str()))
        .flat_map(|info| info.aliases.iter().map(String::as_str))
        .collect();
    let transitioned = |from: JobStatus, to: JobStatus| -> Vec<JobAddr> {
        coverage
            .both
            .iter()
            .filter(|job| {
                base_status.get(job.as_str()) == Some(&from)
                    && head_status.get(job.as_str()) == Some(&to)
            })
            .map(|job| JobAddr(job.clone()))
            .collect()
    };
    BuildDiff {
        regressions: transitioned(JobStatus::Success, JobStatus::Failure),
        new_failures: eval
            .added
            .iter()
            .filter(|job| head_status.get(job.as_str()) == Some(&JobStatus::Failure))
            .cloned()
            .collect(),
        dropped_successes: eval
            .removed
            .iter()
            .filter(|job| {
                !head_aliases.contains(job.as_str())
                    && base_status.get(job.as_str()) == Some(&JobStatus::Success)
            })
            .cloned()
            .collect(),
        fixes: transitioned(JobStatus::Failure, JobStatus::Success),
        existing_failures: transitioned(JobStatus::Failure, JobStatus::Failure),
        case_failure: false,
        missing_results: Vec::new(),
    }
}

/// Jobs a case promised results for but did not deliver, which makes any
/// comparison against it incomplete rather than clean.
fn missing_case_results(
    case: CaseRef<'_, RevSource>,
    mapping: &EvalMap,
    status: &StatusMap,
) -> Result<Vec<String>> {
    let case_id = case.case_id();
    let missing = match case {
        CaseRef::Build(build) => crate::ci::baseline::missing_status(build, mapping, status)?,
        CaseRef::Spot(_) => {
            let delivered: BTreeSet<String> =
                status.keys().map(|job| job.as_str().to_string()).collect();
            selected_case(case, mapping)?
                .difference(&delivered)
                .cloned()
                .collect()
        }
    };
    Ok(missing
        .into_iter()
        .map(|name| format!("{case_id}:{name}"))
        .collect())
}

/// One candidate's halves from loaded state: the eval half always, the build
/// half when both sides' statuses are given. The pure core of [`project`].
pub fn compare_loaded(
    base_case: CaseRef<'_, RevSource>,
    base_map: &EvalMap,
    head_case: CaseRef<'_, RevSource>,
    head_map: &EvalMap,
    statuses: Option<(&StatusMap, &StatusMap)>,
) -> Result<(EvalDiff, Option<BuildDiff>)> {
    let coverage = coverage(base_case, base_map, head_case, head_map)?;
    let eval = eval_diff(&coverage, base_map, head_map);
    let builds = statuses
        .map(|(base_status, head_status)| {
            build_diff(&coverage, &eval, head_map, base_status, head_status)
        });
    Ok((eval, builds))
}

#[allow(clippy::too_many_arguments)]
fn candidate_halves(
    base_case: CaseRef<'_, RevSource>,
    base_map: &EvalMap,
    base_paths: &Path,
    head_case: CaseRef<'_, RevSource>,
    head_map: &EvalMap,
    head_paths: &Path,
    finished: bool,
) -> Result<(EvalDiff, Option<BuildDiff>)> {
    let base_status = case_status(base_paths);
    let head_status = case_status(head_paths);
    let with_builds = finished || (!base_status.is_empty() && !head_status.is_empty());
    let (eval, builds) = compare_loaded(
        base_case,
        base_map,
        head_case,
        head_map,
        with_builds.then_some((&base_status, &head_status)),
    )?;
    let builds = match builds {
        None => None,
        Some(mut builds) => {
            let mut missing = missing_case_results(base_case, base_map, &base_status)?;
            missing.extend(missing_case_results(head_case, head_map, &head_status)?);
            builds.case_failure = !missing.is_empty();
            builds.missing_results = missing;
            Some(builds)
        }
    };
    Ok((eval, builds))
}

fn try_load_map(case: &Path) -> Option<EvalMap> {
    crate::support::schema::read(&crate::ci::prepare::eval_map_path(case)).ok()
}

/// Derive every candidate's comparison from the run's persisted case state:
/// the eval half once both maps exist, the build half once both sides carry
/// results (or unconditionally at finish, where absence is incompleteness).
pub fn project(
    run_dir: &Path,
    request: &crate::ci::types::ResolvedRequest,
    finished: bool,
) -> Result<Vec<Comparison>> {
    let crate::ci::types::Request::Diff(diff) = request else {
        return Ok(Vec::new());
    };
    let Some(baseline) = diff
        .cases
        .iter()
        .find(|case| case.case_id() == diff.baseline)
    else {
        return request_error("diff has no baseline case");
    };
    let base_paths = crate::ci::prepare::case_dir(run_dir, baseline.case_id());
    let base_map = try_load_map(&base_paths);
    let mut comparisons = Vec::new();
    for candidate in &diff.cases {
        if candidate.case_id() == diff.baseline {
            continue;
        }
        let head_paths = crate::ci::prepare::case_dir(run_dir, candidate.case_id());
        let head_map = try_load_map(&head_paths);
        let mut comparison = Comparison {
            candidate: candidate.case_id().to_string(),
            base_evaluated: base_map.is_some(),
            head_evaluated: head_map.is_some(),
            eval: None,
            builds: None,
        };
        if let (Some(base_map), Some(head_map)) = (&base_map, &head_map) {
            // A candidate whose selection cannot resolve against its own map
            // is that case's failure, already reported by its tasks; it must
            // not take down the fold deriving everyone else's comparison.
            match candidate_halves(baseline.as_ref(), base_map, &base_paths, candidate.as_ref(), head_map, &head_paths, finished) {
                Ok((eval, builds)) => {
                    comparison.eval = Some(eval);
                    comparison.builds = builds;
                }
                Err(error) => crate::support::ui::warning(format!(
                    "no comparison for {}: {error}",
                    comparison.candidate
                )),
            }
        }
        comparisons.push(comparison);
    }
    Ok(comparisons)
}
