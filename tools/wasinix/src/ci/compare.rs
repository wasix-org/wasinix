//! Compare two evaluated and built cases by stable job name.
//!
//! This is the product: everything else exists to put two comparable cases in
//! front of it. It computes facts; rendering lives with the other renderers.

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
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub changelogs: Vec<String>,
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

/// Parse nix-fast-build's junit. A job is a failure if any run of it failed.
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

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Comparison {
    /// Jobs both cases cover that stopped passing.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub regressions: Vec<JobAddr>,
    /// Jobs only the candidate covers that fail. They cannot transition, so
    /// without this a newly added broken package reads as green.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub new_failures: Vec<JobAddr>,
    /// Jobs only the baseline covers that were passing when they vanished.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dropped_successes: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub fixes: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub existing_failures: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub new_eval_errors: Vec<JobAddr>,
    pub selected_count: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub rebuilt: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub identity_changed: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub identity_transitions: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub version_updates: Vec<VersionUpdate>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub added: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub removed: Vec<JobAddr>,
    /// Job -> the version it serves, for rendering. Every list in this report
    /// names jobs; a reader wants to know which version each one is.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub identities: BTreeMap<JobAddr, String>,
    #[serde(default)]
    pub case_failure: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub missing_results: Vec<String>,
}

impl Comparison {
    /// Everything that fails the comparison, however the job entered it.
    pub fn regression_count(&self) -> usize {
        self.regressions.len()
            + self.new_failures.len()
            + self.dropped_successes.len()
            + self.new_eval_errors.len()
            + usize::from(self.case_failure)
    }
}

pub fn compare_case_results(
    base_case: CaseRef<'_, RevSource>,
    base_map: &EvalMap,
    base_status: &StatusMap,
    head_case: CaseRef<'_, RevSource>,
    head_map: &EvalMap,
    head_status: &StatusMap,
) -> Result<Comparison> {
    let base_selected = selected_case(base_case, base_map)?;
    let head_selected = selected_case(head_case, head_map)?;
    let both: Vec<&String> = base_selected.intersection(&head_selected).collect();
    let common_coverage =
        matches!(base_case, CaseRef::Spot(_)) || matches!(head_case, CaseRef::Spot(_));
    if common_coverage && both.is_empty() {
        return request_error("diff cases have no shared target coverage");
    }

    let transitioned = |from: JobStatus, to: JobStatus| -> Vec<JobAddr> {
        both.iter()
            .filter(|job| {
                base_status.get(job.as_str()) == Some(&from)
                    && head_status.get(job.as_str()) == Some(&to)
            })
            .map(|job| JobAddr((*job).clone()))
            .collect()
    };

    let added: Vec<JobAddr> = if common_coverage {
        Vec::new()
    } else {
        head_selected
            .difference(&base_selected)
            .cloned()
            .map(JobAddr)
            .collect()
    };
    let removed: Vec<JobAddr> = if common_coverage {
        Vec::new()
    } else {
        base_selected
            .difference(&head_selected)
            .cloned()
            .map(JobAddr)
            .collect()
    };
    let identity_changed: Vec<JobAddr> = both
        .iter()
        .filter(|job| base_map.identity(job) != head_map.identity(job))
        .map(|job| JobAddr((*job).clone()))
        .collect();
    // Keyed by the package's own changelog as well as its subject: two
    // different packages can share a display subject and a version move, and
    // must not merge into one row with unioned changelogs.
    type UpdateKey = (String, String, String, Option<String>);
    let mut version_updates: BTreeMap<UpdateKey, VersionUpdate> = BTreeMap::new();
    for job in &both {
        let (Some(before), Some(after)) = (base_map.version(job), head_map.version(job)) else {
            continue;
        };
        if before == after {
            continue;
        }
        let info = head_map.info.get(job.as_str());
        let subject = info
            .and_then(|info| info.subject.clone().or_else(|| info.display_name.clone()))
            .unwrap_or_else(|| (*job).clone());
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
                changelogs: changelog.into_iter().collect(),
                jobs: Vec::new(),
            });
        update.jobs.push(JobAddr((*job).clone()));
    }

    Ok(Comparison {
        regressions: transitioned(JobStatus::Success, JobStatus::Failure),
        new_failures: added
            .iter()
            .filter(|job| head_status.get(job.as_str()) == Some(&JobStatus::Failure))
            .cloned()
            .collect(),
        dropped_successes: removed
            .iter()
            .filter(|job| base_status.get(job.as_str()) == Some(&JobStatus::Success))
            .cloned()
            .collect(),
        fixes: transitioned(JobStatus::Failure, JobStatus::Success),
        existing_failures: transitioned(JobStatus::Failure, JobStatus::Failure),
        new_eval_errors: both
            .iter()
            .filter(|job| {
                head_map.errors.contains_key(job.as_str())
                    && !base_map.errors.contains_key(job.as_str())
            })
            .map(|job| JobAddr((**job).clone()))
            .collect(),
        selected_count: if common_coverage {
            both.len()
        } else {
            base_selected.union(&head_selected).count()
        },
        rebuilt: both
            .iter()
            .filter(|job| {
                base_map.jobs.get(job.as_str()) != head_map.jobs.get(job.as_str())
                    && head_map.rebuild_signal(job)
            })
            .map(|job| JobAddr((*job).clone()))
            .collect(),
        identity_transitions: identity_changed
            .iter()
            .map(|job| {
                format!(
                    "{job}: {} -> {}",
                    base_map.identity(job.as_str()).unwrap_or_else(|| "?".into()),
                    head_map.identity(job.as_str()).unwrap_or_else(|| "?".into())
                )
            })
            .collect(),
        version_updates: version_updates.into_values().collect(),
        identity_changed,
        // A removed job has no head identity, so the base is the only side
        // that can say which version went away.
        identities: if common_coverage {
            both.into_iter().cloned().collect::<BTreeSet<_>>()
        } else {
            base_selected.union(&head_selected).cloned().collect()
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
        case_failure: false,
        missing_results: Vec::new(),
    })
}
