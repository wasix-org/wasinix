//! The evaluation of one case: which jobs exist, what they build to, and the
//! policy each job declares.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::support::atoms::{JobAddr, JobStatus, Rev};
use crate::support::error::{Result, request_error};
use crate::support::naming::{self, Domain};
use crate::support::schema::Document;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ExpectedOutcome {
    Xfail,
    Broken,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct TestExpectation {
    pub outcome: ExpectedOutcome,
    pub reason: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JobInfo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub test_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub test_family: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub variant: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact_kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changelog: Option<String>,
    /// Absent means 1. Kept optional so a map round-trips unchanged: this type
    /// both reads published maps and writes them.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rel: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub role: Option<String>,
    /// Previous or alternate job addresses that this job preserves.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub aliases: Vec<String>,
    /// Capabilities a CI request must enable before scheduling this job.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tags: Vec<String>,
    /// Whether a moved derivation for this job means anything downstream.
    #[serde(default = "yes")]
    pub rebuild_signal: bool,
    #[serde(default)]
    pub content_diff: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub test_expectation: Option<TestExpectation>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spot_target: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spot_owner: Option<String>,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectorGroup {
    #[serde(default)]
    pub jobs: Vec<String>,
    #[serde(default)]
    pub spot_owners: Vec<String>,
}

/// The flake's selector catalog (`.#ciSelectorCatalog`): a nix evaluation
/// payload, not one of this tool's documents, so it carries no envelope.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct SelectorCatalog {
    pub schema_version: u64,
    #[serde(default)]
    pub jobs: Vec<String>,
    #[serde(default)]
    pub info: BTreeMap<JobAddr, JobInfo>,
    #[serde(default)]
    pub sets: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub groups: BTreeMap<String, SelectorGroup>,
}

impl SelectorCatalog {
    pub fn into_map(self) -> EvalMap {
        EvalMap {
            jobs: self
                .jobs
                .into_iter()
                .map(|name| (JobAddr(name), String::new()))
                .collect(),
            info: self.info,
            sets: self.sets,
            groups: self.groups,
            ..EvalMap::default()
        }
    }
}

/// Per-job outcomes, present only on a published baseline.
pub type StatusMap = BTreeMap<JobAddr, JobStatus>;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalMap {
    /// The revision this evaluation describes, so a published map can be
    /// matched to the commit it came from.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rev: Option<Rev>,
    #[serde(default)]
    pub jobs: BTreeMap<JobAddr, String>,
    /// Output paths per job, which content comparison needs to tell a moved
    /// derivation from changed content.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub outputs: BTreeMap<JobAddr, BTreeMap<String, String>>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub errors: BTreeMap<JobAddr, String>,
    #[serde(default)]
    pub info: BTreeMap<JobAddr, JobInfo>,
    #[serde(default)]
    pub sets: BTreeMap<String, Vec<String>>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub groups: BTreeMap<String, SelectorGroup>,
    /// Update-note versions as of this evaluation; a later run diffs against
    /// them to decide which notes fired.
    #[serde(default, skip_serializing_if = "serde_json::Value::is_null")]
    pub note_versions: serde_json::Value,
    /// Per-job status, present only on a published baseline.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub status: Option<StatusMap>,
    /// The jobs a published baseline promises status for; a partial or
    /// interrupted build cannot be told apart from a complete one by its
    /// status map alone.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub coverage: Vec<JobAddr>,
    /// Per-job build wall time, present only on a published baseline.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub build_seconds: BTreeMap<JobAddr, f64>,
    /// Per-task wall time, present only on a published baseline. The job
    /// times above account for the build alone; a run also spends its time
    /// evaluating, warming inputs, and formatting.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub task_seconds: Vec<TaskTiming>,
}

/// One pipeline task's wall time, carrying the label so a reader needs no
/// second document to name it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskTiming {
    pub task_id: String,
    pub label: String,
    pub seconds: f64,
}

impl Document for EvalMap {
    const KIND: &'static str = "evalMap";
    const SCHEMA: u32 = 1;
}

impl EvalMap {
    /// Every name a selector completer should offer, or None for a map too
    /// narrow to describe the world (a spot case carries only its own jobs
    /// and must not shrink the recorded set).
    pub fn selector_names(&self) -> Option<Vec<&str>> {
        if self.sets.is_empty() {
            return None;
        }
        Some(
            std::iter::once("all")
                .chain(self.sets.keys().map(String::as_str))
                .chain(self.groups.keys().map(String::as_str))
                .chain(self.jobs.keys().map(JobAddr::as_str))
                .collect(),
        )
    }

    /// Refresh the shell-completion cache from this map.
    pub fn record_completions(&self) {
        if let Some(names) = self.selector_names() {
            crate::support::completions::record("selectors", names);
        }
    }

    /// The map an evaluation's job lines describe. Errors keep their first
    /// line; the full text stays in the evaluation log.
    pub fn from_jobs(rev: Rev, jobs: &[crate::nix::evaljobs::EvalJob]) -> EvalMap {
        let mut map = EvalMap {
            rev: Some(rev),
            ..EvalMap::default()
        };
        for job in jobs {
            let name = JobAddr(job.name());
            match &job.error {
                Some(error) => {
                    map.errors
                        .insert(name, error.lines().next().unwrap_or_default().to_string());
                }
                None => {
                    map.jobs
                        .insert(name.clone(), job.drv_path.clone().unwrap_or_default());
                    map.outputs.insert(name, job.outputs.clone());
                }
            }
        }
        map
    }

    pub fn version(&self, job: &str) -> Option<String> {
        let version = self.info.get(job)?.version.as_ref()?;
        let rendered = match version {
            serde_json::Value::String(text) => text.clone(),
            other => other.to_string(),
        };
        (!rendered.is_empty()).then_some(rendered)
    }

    pub fn missing_tags(&self, job: &str, enabled: &[String]) -> Vec<String> {
        self.info
            .get(job)
            .map(|info| {
                info.tags
                    .iter()
                    .filter(|tag| !enabled.contains(tag))
                    .cloned()
                    .collect()
            })
            .unwrap_or_default()
    }

    pub fn tag_enabled(&self, job: &str, enabled: &[String]) -> bool {
        self.missing_tags(job, enabled).is_empty()
    }

    /// The jobs a set selection quietly leaves out and why, so a report can
    /// say "N jobs omitted: tags X, Y" instead of omitting silently.
    pub fn omitted_by_tags(&self, enabled: &[String]) -> BTreeMap<String, Vec<JobAddr>> {
        let mut omitted: BTreeMap<String, Vec<JobAddr>> = BTreeMap::new();
        for job in self.jobs.keys() {
            for tag in self.missing_tags(&job.0, enabled) {
                omitted.entry(tag).or_default().push(job.clone());
            }
        }
        omitted
    }

    /// Resolve explicit selectors and reject gated matches. Set selection uses
    /// omission, but an explicit request must never succeed without its jobs.
    pub fn resolve_enabled_jobs(
        &self,
        requested: &[String],
        enabled: &[String],
    ) -> Result<Vec<String>> {
        let jobs = self.resolve_jobs(requested)?;
        let blocked: Vec<String> = jobs
            .iter()
            .filter_map(|job| {
                let missing = self.missing_tags(job, enabled);
                (!missing.is_empty()).then(|| format!("{job} ({})", missing.join(", ")))
            })
            .collect();
        if !blocked.is_empty() {
            return request_error(format!(
                "selected CI jobs require disabled tags: {}; pass --enable-tag for every listed tag",
                blocked.join("; ")
            ));
        }
        Ok(jobs)
    }

    /// The jobs this evaluation found, as addresses. A flat job name is the
    /// segments joined, so splitting it back is exact for every root whose
    /// names hold no dot, and the joined form is accepted for the rest.
    pub fn job_domain(&self) -> Domain {
        let mut domain = Domain::new("the evaluated job list");
        for name in self.jobs.keys().chain(self.errors.keys()) {
            let path: Vec<String> = name.0.split('.').map(str::to_string).collect();
            let axis = naming::axis_of(&path);
            domain.add_path(path, &name.0, axis, Vec::new());
        }
        domain
    }

    /// The job names a request's addresses select. An address naming one
    /// package across a variant axis selects every build of it, which is how
    /// `packagesByProfile.zlib` covers all five profiles.
    pub fn resolve_jobs(&self, requested: &[String]) -> Result<Vec<String>> {
        let domain = self.job_domain();
        let mut jobs = Vec::new();
        for spec in requested {
            if let Some(group) = self.groups.get(spec) {
                if group.jobs.is_empty() {
                    return request_error(format!("CI selector group {spec:?} has no jobs"));
                }
                extend_unique(&mut jobs, &group.jobs);
                continue;
            }
            if spec == "all" {
                for members in self.sets.values() {
                    extend_unique(&mut jobs, members);
                }
                continue;
            }
            if let Some(members) = self.sets.get(spec) {
                extend_unique(&mut jobs, members);
                continue;
            }
            let parsed = naming::parse(spec)?;
            if parsed.value.is_some() {
                return request_error(format!("{spec}: a CI job takes no version"));
            }
            for resolved in domain.resolve(&parsed)? {
                if !jobs.contains(&resolved.key) {
                    jobs.push(resolved.key);
                }
            }
        }
        Ok(jobs)
    }

    pub fn resolve_spot_targets(&self, requested: &[String]) -> Result<Vec<String>> {
        let mut targets = Vec::new();
        for spec in requested {
            let mut matched = false;
            for job in self.resolve_jobs(std::slice::from_ref(spec))? {
                if let Some(target) = self
                    .info
                    .get(job.as_str())
                    .and_then(|info| info.spot_target.as_ref())
                {
                    matched = true;
                    push_unique(&mut targets, target);
                }
            }
            if !matched {
                return request_error(format!(
                    "spot target {spec:?} selects no cross-package CI jobs"
                ));
            }
        }
        Ok(targets)
    }

    pub fn resolve_spot_sources(&self, requested: &[String]) -> Result<Vec<String>> {
        let mut owners = Vec::new();
        for spec in requested {
            if let Some(group) = self.groups.get(spec) {
                if group.spot_owners.is_empty() {
                    return request_error(format!(
                        "CI selector group {spec:?} has no Spot source projection"
                    ));
                }
                extend_unique(&mut owners, &group.spot_owners);
                continue;
            }
            let jobs = self.resolve_jobs(std::slice::from_ref(spec))?;
            let mut matched = false;
            for job in jobs {
                if let Some(owner) = self
                    .info
                    .get(job.as_str())
                    .and_then(|info| info.spot_owner.as_ref())
                {
                    matched = true;
                    push_unique(&mut owners, owner);
                }
            }
            if !matched {
                return request_error(format!(
                    "spot source {spec:?} selects no cross-package CI jobs"
                ));
            }
        }
        Ok(owners)
    }

    /// The identity a publication carries: version plus release counter, which
    /// changes even when the derivation does not.
    pub fn identity(&self, job: &str) -> Option<String> {
        let info = self.info.get(job)?;
        let rendered = self.version(job)?;
        let rel = info.rel.unwrap_or(1);
        Some(if rel > 1 {
            format!("{rendered} r{rel}")
        } else {
            rendered
        })
    }

    pub fn rebuild_signal(&self, job: &str) -> bool {
        self.info
            .get(job)
            .map(|info| info.rebuild_signal)
            .unwrap_or(true)
    }
}

fn push_unique(values: &mut Vec<String>, value: &str) {
    if !values.iter().any(|existing| existing == value) {
        values.push(value.to_string());
    }
}

fn extend_unique(values: &mut Vec<String>, additions: &[String]) {
    for value in additions {
        push_unique(values, value);
    }
}
