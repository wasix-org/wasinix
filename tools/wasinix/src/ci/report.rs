//! Task fragments and the report folded from them. The verdict is computed by
//! the fold and nowhere else; rendering consumes the folded [`Report`], never
//! the fragments.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::ci::compare::{Comparison, VersionUpdate};
use crate::ci::contentdiff::ContentSummary;
use crate::ci::facts::{BuildFacts, Failure};
use crate::ci::plan::{Plan, Task, TaskKind};
use crate::ci::types::ResolvedRequest;
use crate::support::atoms::{Bytes, DurationSecs, Rev, TaskStatus};
use crate::support::error::{Error, Result};
use crate::support::schema::{self, Document};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Annotation {
    pub path: String,
    pub line: u32,
    pub title: String,
    pub message: String,
}

/// The evaluation task's outcome: how many jobs exist, what a set selection
/// left out, and (in a diff) what moved against the base.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EvalSummary {
    pub job_count: usize,
    /// Tag -> how many jobs the selection omitted for lacking it. Never
    /// silent: a set selection that filtered jobs says so here.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub omitted_by_tags: BTreeMap<String, usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_rev: Option<Rev>,
}

/// Captured tool output for the tasks whose product is text (formatting,
/// input warming, spot builds). Capped at write time.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct LogExcerpt {
    pub lines: Vec<String>,
    #[serde(default)]
    pub truncated: bool,
}

/// What a task's fragment carries, typed per phase. A fragment that fails to
/// decode is a hard error at load, never a silently empty report section.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum FragmentData {
    Build(BuildFacts),
    Comparison(Box<Comparison>),
    Eval(EvalSummary),
    Content(ContentSummary),
    Log(LogExcerpt),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Fragment {
    pub task_id: String,
    pub label: String,
    #[serde(rename = "taskKind")]
    pub kind: TaskKind,
    /// Written by tasks; the renderer-only pending/deferred states never
    /// reach disk.
    pub status: TaskStatus,
    pub headline: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub data: Option<FragmentData>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub elapsed_seconds: Option<DurationSecs>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact_bytes: Option<Bytes>,
}

impl Document for Fragment {
    const KIND: &'static str = "fragment";
    const SCHEMA: u32 = 1;
}

impl Fragment {
    pub fn new(
        task_id: impl Into<String>,
        label: impl Into<String>,
        kind: TaskKind,
        status: TaskStatus,
        headline: impl Into<String>,
    ) -> Fragment {
        assert!(
            !matches!(status, TaskStatus::Pending | TaskStatus::Deferred),
            "pending/deferred are renderer states, never written by a task"
        );
        Fragment {
            task_id: task_id.into(),
            label: label.into(),
            kind,
            status,
            headline: headline.into(),
            data: None,
            elapsed_seconds: None,
            artifact_bytes: None,
        }
    }

    pub fn with_data(mut self, data: FragmentData) -> Fragment {
        self.data = Some(data);
        self
    }

    pub fn write(&self, path: &Path) -> Result<()> {
        schema::write(path, self)
    }
}

/// Every fragment under a directory, keyed by task. A file that exists but
/// does not decode fails the fold: a corrupt fragment must never read as an
/// absent task.
pub fn fragments_under(dir: &Path) -> Result<BTreeMap<String, Fragment>> {
    let mut found = BTreeMap::new();
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(found),
        Err(error) => return Err(crate::support::error::io(dir, error)),
    };
    let mut files: Vec<std::path::PathBuf> = Vec::new();
    for entry in entries {
        let path = entry.map_err(|e| crate::support::error::io(dir, e))?.path();
        if path.extension().is_some_and(|ext| ext == "json") {
            files.push(path);
        }
    }
    files.sort();
    for file in files {
        let fragment: Fragment = schema::read(&file)?;
        if fragment.task_id.is_empty() {
            return Err(Error::Failure(format!(
                "{}: fragment names no task",
                file.display()
            )));
        }
        found.insert(fragment.task_id.clone(), fragment);
    }
    Ok(found)
}

/// One plan task joined with whatever reported about it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TaskView {
    pub task_id: String,
    pub label: String,
    pub kind: TaskKind,
    pub case: String,
    pub status: TaskStatus,
    pub gate: bool,
    pub enabled: bool,
    pub headline: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub elapsed_seconds: Option<DurationSecs>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub artifact_bytes: Option<Bytes>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Conclusion {
    Success,
    Failure,
    Neutral,
}

impl Conclusion {
    /// The word GitHub's check-run API takes.
    pub fn as_github(self) -> &'static str {
        match self {
            Conclusion::Success => "success",
            Conclusion::Failure => "failure",
            Conclusion::Neutral => "neutral",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub conclusion: Option<Conclusion>,
    /// Whether the check can be closed. A required failure terminally blocks
    /// its downstream tasks, so their missing fragments must not hold it
    /// open; a finished run resolves everything still pending.
    pub complete: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub finished_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub annotations: Vec<Annotation>,
    pub tasks: Vec<TaskView>,
    /// Per build task, the Failure atoms it produced.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub failures: BTreeMap<String, Vec<Failure>>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub version_updates: BTreeMap<String, Vec<VersionUpdate>>,
    /// The request this run executed, echoed so a reader can tell what was
    /// selected without reconstructing it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request: Option<ResolvedRequest>,
}

impl Document for Report {
    const KIND: &'static str = "report";
    const SCHEMA: u32 = 1;
}

/// Everything the fold needs to know beyond plan and fragments.
#[derive(Debug, Default)]
pub struct FoldContext {
    /// The diff's baseline case id, when the run is a diff: failures confined
    /// to the baseline's own evaluation are the base's condition, not the
    /// candidate's, and conclude neutral.
    pub baseline_case: Option<String>,
    /// Whether the run's process is over. A finished run resolves pending
    /// tasks as cancelled instead of holding the report open forever.
    pub finished: bool,
    pub started_at: Option<u64>,
    pub finished_at: Option<u64>,
    pub request: Option<ResolvedRequest>,
}

/// A check-run annotation anchored at the failing package's definition.
/// meta.position points into the evaluated store copy of the repo, so the
/// part after the source root is the repo-relative path GitHub can anchor.
fn annotation_of(failure: &crate::ci::facts::Failure) -> Option<Annotation> {
    let position = failure.position.as_deref()?;
    let (path, line) = position.rsplit_once(':')?;
    let line: u32 = line.parse().ok()?;
    let path = match path.split_once("-source/") {
        Some((_, relative)) => relative,
        None => path.strip_prefix('/').unwrap_or(path),
    };
    Some(Annotation {
        path: path.to_string(),
        line,
        title: failure.job.0.chars().take(255).collect(),
        message: failure
            .message
            .as_deref()
            .unwrap_or("build failed")
            .chars()
            .take(1000)
            .collect(),
    })
}

fn failed(status: TaskStatus) -> bool {
    status.is_failure()
}

/// Fold plan and fragments into the one verdict.
pub fn fold(
    plan: &Plan,
    fragments: &BTreeMap<String, Fragment>,
    context: FoldContext,
) -> Report {
    struct View<'a> {
        task: &'a Task,
        fragment: Option<&'a Fragment>,
        status: TaskStatus,
    }

    let mut views: Vec<View> = plan
        .tasks
        .iter()
        .map(|task| {
            let fragment = fragments.get(&task.task_id);
            let status = match fragment {
                Some(fragment) => fragment.status,
                None if !task.enabled => TaskStatus::Deferred,
                None if context.finished => TaskStatus::Cancelled,
                None => TaskStatus::Pending,
            };
            View {
                task,
                fragment,
                status,
            }
        })
        .collect();

    // A required failure terminally blocks everything ordered after it in the
    // same case; those tasks will never report, and must not read as pending.
    let blocked: Vec<(String, u32)> = views
        .iter()
        .filter(|view| view.task.gate && failed(view.status))
        .map(|view| (view.task.case.clone(), view.task.order))
        .collect();
    for view in views.iter_mut() {
        if view.status == TaskStatus::Pending
            && blocked
                .iter()
                .any(|(case, order)| *case == view.task.case && *order < view.task.order)
        {
            view.status = TaskStatus::Skipped;
        }
    }

    let failed_gates = views
        .iter()
        .filter(|view| view.task.enabled && view.task.gate && failed(view.status))
        .count();
    let pending_gates = views
        .iter()
        .filter(|view| {
            view.task.enabled && view.task.gate && view.status == TaskStatus::Pending
        })
        .count();
    let advisory_failures = views
        .iter()
        .filter(|view| {
            view.task.enabled
                && !view.task.gate
                && (failed(view.status) || view.status == TaskStatus::Neutral)
        })
        .count();
    let active_failures = views
        .iter()
        .filter(|view| view.task.enabled && failed(view.status))
        .count();

    // Failed gates whose case is the diff baseline (or that went hungry
    // because the baseline never evaluated) are the base's condition, not the
    // submitted change's: the run concludes neutral, never red.
    let baseline_only = failed_gates > 0
        && context.baseline_case.as_deref().is_some_and(|baseline| {
            views
                .iter()
                .filter(|view| view.task.enabled && view.task.gate && failed(view.status))
                .all(|view| {
                    view.task.case == baseline
                        || (view.task.kind == TaskKind::Comparison && view.fragment.is_none())
                })
        });

    let (conclusion, title) = if failed_gates > 0 && baseline_only {
        (
            Some(Conclusion::Neutral),
            "CI could not compare: the base did not evaluate".to_string(),
        )
    } else if failed_gates > 0 {
        (Some(Conclusion::Failure), "CI failed".to_string())
    } else if pending_gates > 0 {
        let title = if active_failures > 0 {
            format!("CI running with {active_failures} failed")
        } else {
            "CI in progress".to_string()
        };
        (None, title)
    } else if !plan.tasks.is_empty() || !fragments.is_empty() {
        let title = if advisory_failures > 0 {
            format!("CI passed with {advisory_failures} advisory failures")
        } else {
            "CI passed".to_string()
        };
        (Some(Conclusion::Success), title)
    } else {
        (
            Some(Conclusion::Failure),
            "CI produced no results".to_string(),
        )
    };

    let complete = failed_gates > 0 || pending_gates == 0;

    let annotations = views
        .iter()
        .filter(|view| view.task.enabled)
        .filter_map(|view| match view.fragment?.data.as_ref()? {
            FragmentData::Build(facts) => Some(&facts.failures),
            _ => None,
        })
        .flatten()
        .filter_map(annotation_of)
        .collect();
    let tasks = views
        .iter()
        .map(|view| TaskView {
            task_id: view.task.task_id.clone(),
            label: view.task.label.clone(),
            kind: view.task.kind,
            case: view.task.case.clone(),
            status: view.status,
            gate: view.task.gate,
            enabled: view.task.enabled,
            headline: view
                .fragment
                .map(|fragment| fragment.headline.clone())
                .unwrap_or_default(),
            elapsed_seconds: view.fragment.and_then(|fragment| fragment.elapsed_seconds),
            artifact_bytes: view.fragment.and_then(|fragment| fragment.artifact_bytes),
        })
        .collect();
    let failures = views
        .iter()
        .filter(|view| view.task.enabled)
        .filter_map(|view| match view.fragment?.data.as_ref()? {
            FragmentData::Build(facts) if !facts.failures.is_empty() => {
                Some((view.task.task_id.clone(), facts.failures.clone()))
            }
            _ => None,
        })
        .collect();
    let version_updates = views
        .iter()
        .filter(|view| view.task.enabled)
        .filter_map(|view| match view.fragment?.data.as_ref()? {
            FragmentData::Comparison(comparison) if !comparison.version_updates.is_empty() => {
                Some((view.task.task_id.clone(), comparison.version_updates.clone()))
            }
            _ => None,
        })
        .collect();

    Report {
        title,
        conclusion,
        complete,
        started_at: context.started_at,
        finished_at: context.finished_at,
        annotations,
        tasks,
        failures,
        version_updates,
        request: context.request,
    }
}

/// The terminal report for a run that ended without folding one: a cancel, a
/// timeout, a lost supervisor. Without this, the surfaces stay wedged on the
/// last in-progress render (the check run in_progress forever); with it, the
/// check completes and the comment states what happened.
pub fn from_run_state(run: &crate::runs::Run) -> Report {
    use crate::support::atoms::RunState;
    let title = match run.state {
        RunState::Cancelled => "CI was cancelled".to_string(),
        RunState::TimedOut => "CI timed out".to_string(),
        RunState::Lost => "CI lost its runner before finishing".to_string(),
        _ => format!("CI ended as {} without a report", run.state),
    };
    Report {
        title,
        conclusion: Some(Conclusion::Failure),
        complete: true,
        started_at: Some(run.started_at),
        finished_at: run.finished_at,
        annotations: Vec::new(),
        tasks: Vec::new(),
        failures: std::collections::BTreeMap::new(),
        version_updates: std::collections::BTreeMap::new(),
        request: None,
    }
}
