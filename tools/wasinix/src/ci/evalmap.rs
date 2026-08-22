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
    pub package_subject: Option<String>,
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
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectorGroup {
    #[serde(default)]
    pub jobs: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogCiPolicy {
    #[serde(default)]
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogPublication {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub version: Option<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rel: Option<u32>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogPolicy {
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub ci: CatalogCiPolicy,
    #[serde(default)]
    pub publication: CatalogPublication,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogInstance {
    #[serde(default)]
    pub version: serde_json::Value,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CatalogJob {
    pub kind: String,
    pub name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub package_subject: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub test_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact_kind: Option<String>,
    #[serde(default)]
    pub variant: serde_json::Value,
    #[serde(default)]
    pub instance: CatalogInstance,
    #[serde(default)]
    pub policy: CatalogPolicy,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spot_target: Option<String>,
}

impl CatalogJob {
    fn into_info(self) -> JobInfo {
        let variant = self
            .variant
            .get("profile")
            .or_else(|| self.variant.get("interpreter"))
            .and_then(serde_json::Value::as_str)
            .map(str::to_owned);
        let is_test = self.kind == "test";
        JobInfo {
            display_name: Some(self.name.clone()),
            subject: self.subject.or(Some(self.name)),
            package_subject: self.package_subject,
            test_name: self.test_name,
            variant,
            artifact_kind: self.artifact_kind,
            version: self
                .policy
                .publication
                .version
                .or_else(|| (!self.instance.version.is_null()).then_some(self.instance.version)),
            rel: self.policy.publication.rel,
            role: Some(if is_test { "check" } else { "artifact" }.to_owned()),
            aliases: self.policy.aliases,
            tags: self.policy.ci.tags,
            content_diff: !is_test,
            spot_target: self.spot_target,
            ..JobInfo::default()
        }
    }
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct CatalogSelectors {
    #[serde(default)]
    pub sets: BTreeMap<String, Vec<String>>,
    #[serde(default)]
    pub groups: BTreeMap<String, SelectorGroup>,
}

/// The flake's `ci.catalog` evaluation payload.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectorCatalog {
    pub schema_version: u64,
    #[serde(default)]
    pub jobs: BTreeMap<JobAddr, CatalogJob>,
    #[serde(default)]
    pub packages: BTreeMap<JobAddr, CatalogJob>,
    #[serde(default)]
    pub selectors: CatalogSelectors,
}

impl SelectorCatalog {
    pub fn into_map(self) -> EvalMap {
        let info = self
            .jobs
            .iter()
            .map(|(address, job)| (address.clone(), job.clone().into_info()))
            .collect();
        EvalMap {
            jobs: self
                .jobs
                .into_keys()
                .map(|address| (address, String::new()))
                .collect(),
            info,
            packages: self.packages,
            sets: self.selectors.sets,
            groups: self.selectors.groups,
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
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub packages: BTreeMap<JobAddr, CatalogJob>,
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
            let aliases = self
                .info
                .get(name)
                .map(|info| info.aliases.clone())
                .unwrap_or_default();
            domain.add_path(path, &name.0, axis, aliases);
        }
        domain
    }

    /// The job names a request's addresses select. An address naming one
    /// package across a variant axis selects every build of it, which is how
    /// `packages.wasix.zlib` covers every supported profile.
    pub fn resolve_jobs(&self, requested: &[String]) -> Result<Vec<String>> {
        let domain = self.job_domain();
        let mut jobs = Vec::new();
        for spec in requested {
            if let Some(group) = self.groups.get(spec) {
                let available: Vec<String> = group
                    .jobs
                    .iter()
                    .filter(|job| {
                        let address = JobAddr((*job).clone());
                        self.jobs.contains_key(&address) || self.errors.contains_key(&address)
                    })
                    .cloned()
                    .collect();
                if available.is_empty() {
                    return request_error(format!("CI selector group {spec:?} has no jobs"));
                }
                extend_unique(&mut jobs, &available);
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

    pub fn resolve_packages(&self, requested: &[String]) -> Result<Vec<String>> {
        let mut sources = Vec::new();
        let mut domain = Domain::new("the package catalog");
        for (address, package) in &self.packages {
            let path = naming::split(address.as_str())?;
            domain.add_path(
                path.clone(),
                address.as_str(),
                naming::axis_of(&path),
                package.policy.aliases.clone(),
            );
        }
        for spec in requested {
            let members = if let Some(group) = self.groups.get(spec) {
                group.jobs.clone()
            } else if spec == "all" {
                self.sets.values().flatten().cloned().collect()
            } else if let Some(set) = self.sets.get(spec) {
                set.clone()
            } else {
                let parsed = naming::parse(spec)?;
                if parsed.value.is_some() {
                    return request_error(format!("{spec}: a selected package takes no version"));
                }
                domain
                    .resolve(&parsed)?
                    .into_iter()
                    .map(|resolved| resolved.key)
                    .collect()
            };
            let mut matched = false;
            for member in members {
                let address = JobAddr(member.clone());
                let package = if self.packages.contains_key(&address) {
                    Some(member.as_str())
                } else {
                    self.info
                        .get(&address)
                        .and_then(|info| info.package_subject.as_deref())
                };
                if let Some(package) = package {
                    matched = true;
                    push_unique(&mut sources, package);
                }
            }
            if !matched {
                return request_error(format!(
                    "selector {spec:?} selects no catalogued packages"
                ));
            }
        }
        Ok(sources)
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
