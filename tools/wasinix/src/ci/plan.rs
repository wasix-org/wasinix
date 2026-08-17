//! The run's ordered task list: no dependency edges, because the topology is
//! fixed. It is the ordered list the executor walks and the report expects to
//! see, derived from the request and never stored beside it.

use serde::{Deserialize, Serialize};

use crate::ci::types::{Build, CaseRef, Request, SetName};
use crate::support::schema::Document;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BuildTarget {
    Core,
    Packages,
    Python,
    /// Individually named jobs rather than a whole set.
    Jobs,
}

impl BuildTarget {
    pub fn as_str(self) -> &'static str {
        match self {
            BuildTarget::Core => "core",
            BuildTarget::Packages => "packages",
            BuildTarget::Python => "python",
            BuildTarget::Jobs => "jobs",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            BuildTarget::Jobs => "Selected jobs",
            BuildTarget::Core => "Core",
            BuildTarget::Packages => "Packages",
            BuildTarget::Python => "Python",
        }
    }
}

impl From<SetName> for BuildTarget {
    fn from(value: SetName) -> Self {
        match value {
            SetName::Core => BuildTarget::Core,
            SetName::Packages => BuildTarget::Packages,
            SetName::Python => BuildTarget::Python,
        }
    }
}

/// What a task does. Adding a variant is a compile error at every dispatch
/// site, which keeps execution and reporting aligned.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "phase", rename_all = "camelCase")]
pub enum Phase {
    Treefmt,
    EvalInputs,
    Eval,
    Build { set: BuildTarget },
    Spot,
    Content,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TaskKind {
    Validation,
    Eval,
    Build,
    Spot,
    Analysis,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    pub task_id: String,
    pub label: String,
    pub kind: TaskKind,
    pub case: String,
    #[serde(flatten)]
    pub phase: Phase,
    pub order: u32,
    /// Whether this task contributes to the run's required verdict. Distinct
    /// from blocking: a diff's builds run before the comparison but do not
    /// decide it.
    pub gate: bool,
    pub enabled: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    pub tasks: Vec<Task>,
}

impl Document for Plan {
    const KIND: &'static str = "plan";
    const SCHEMA: u32 = 1;
}

struct Builder {
    tasks: Vec<Task>,
    order: u32,
}

impl Builder {
    fn push(
        &mut self,
        task_id: String,
        label: String,
        kind: TaskKind,
        case: &str,
        phase: Phase,
        gate: bool,
    ) {
        self.order += 10;
        self.tasks.push(Task {
            task_id,
            label,
            kind,
            case: case.to_string(),
            phase,
            order: self.order,
            gate,
            enabled: true,
        });
    }
}

fn plan_evaluation<S>(builder: &mut Builder, case: &Build<S>, gate_builds: bool) {
    let id = case.case_id();
    builder.push(
        format!("{id}.eval-inputs"),
        format!("{id}: Evaluation inputs"),
        TaskKind::Eval,
        id,
        Phase::EvalInputs,
        gate_builds,
    );
    builder.push(
        format!("{id}.eval"),
        format!("{id}: Evaluation"),
        TaskKind::Eval,
        id,
        Phase::Eval,
        gate_builds,
    );
}

fn plan_builds<S>(builder: &mut Builder, case: &Build<S>, gate_builds: bool) {
    let id = case.case_id();
    for set in case.requested_sets() {
        let target = BuildTarget::from(set);
        builder.push(
            format!("{id}.{}", target.as_str()),
            format!("{id}: {}", target.label()),
            TaskKind::Build,
            id,
            Phase::Build { set: target },
            gate_builds,
        );
    }
    if !case.requested_jobs().is_empty() {
        builder.push(
            format!("{id}.jobs"),
            format!("{id}: {}", BuildTarget::Jobs.label()),
            TaskKind::Build,
            id,
            Phase::Build {
                set: BuildTarget::Jobs,
            },
            gate_builds,
        );
    }
}

/// Build the task list. `reused` names cases whose results were adopted from a
/// published run, so their evaluation and builds are already satisfied.
pub fn plan_of<S>(request: &Request<S>, request_id: Option<&str>, reused: &[String]) -> Plan {
    let mut builder = Builder {
        tasks: Vec::new(),
        order: 0,
    };
    // A diff is decided by its comparison, not by either side building clean:
    // a failure both cases share is the status quo, not a regression. A
    // candidate must still evaluate for a comparison to exist, so its
    // evaluation gates; a broken baseline is the base's condition and
    // concludes neutral, so nothing on the baseline gates.
    let gate_builds = !request.is_diff();
    let baseline = match request {
        Request::Diff(diff) => Some(diff.baseline.as_str()),
        _ => None,
    };

    let cases = request.cases();
    for case in &cases {
        let id = case.case_id().to_string();
        if baseline != Some(id.as_str()) {
            builder.push(
                format!("{id}.treefmt"),
                format!("{id}: Formatting"),
                TaskKind::Validation,
                &id,
                Phase::Treefmt,
                true,
            );
        }
    }

    for case in &cases {
        let id = case.case_id();
        if reused.iter().any(|reused_id| reused_id == id) {
            continue;
        }
        match case {
            // A failed spot build still lays out its map and statuses, so a
            // failure both sides share stays the comparison's call.
            CaseRef::Spot(_) => builder.push(
                format!("{id}.spot"),
                format!("{id}: Spot"),
                TaskKind::Spot,
                id,
                Phase::Spot,
                gate_builds,
            ),
            CaseRef::Build(build) => {
                plan_evaluation(&mut builder, build, gate_builds || baseline != Some(id))
            }
        }
    }

    for case in &cases {
        if reused.iter().any(|reused_id| reused_id == case.case_id()) {
            continue;
        }
        if let CaseRef::Build(build) = case {
            plan_builds(&mut builder, build, gate_builds);
        }
    }

    if let Request::Diff(diff) = request {
        for case in diff.cases.iter().skip(1) {
            let id = case.case_id().to_string();
            if diff.content_diff {
                builder.push(
                    format!("content-diff.{id}"),
                    format!("Content diff: {id}"),
                    TaskKind::Analysis,
                    &id,
                    Phase::Content,
                    false,
                );
            }
        }
    }

    Plan {
        request_id: request_id.map(str::to_string),
        tasks: builder.tasks,
    }
}
