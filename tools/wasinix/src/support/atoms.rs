//! The shared vocabulary: newtypes whose wire and display formats live on the
//! type, and the only three status enums in the tool.

use serde::{Deserialize, Serialize};

use crate::support::error::{Result, request_error};
use crate::support::format;

/// A resolved git revision: 40 hex characters on the wire, 12 on display.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Rev(String);

impl Rev {
    pub fn parse(text: &str) -> Result<Rev> {
        if text.len() == 40 && text.bytes().all(|b| b.is_ascii_hexdigit()) {
            Ok(Rev(text.to_ascii_lowercase()))
        } else {
            request_error(format!("\"{text}\" is not a full 40-hex git revision"))
        }
    }

    pub fn full(&self) -> &str {
        &self.0
    }

    pub fn short(&self) -> &str {
        format::short_rev(&self.0)
    }
}

impl std::fmt::Display for Rev {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.short())
    }
}

/// Seconds as f64 on the wire (field names end in `Seconds`), the shared
/// duration format on display.
#[derive(Clone, Copy, Debug, Default, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(transparent)]
pub struct DurationSecs(pub f64);

impl std::fmt::Display for DurationSecs {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&format::duration(self.0))
    }
}

/// Raw bytes on the wire (field names end in `Bytes`), binary units on display.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Bytes(pub u64);

impl std::fmt::Display for Bytes {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&format::bytes(self.0))
    }
}

/// A CI job address: the dotted flake attr path that names the job.
#[derive(Clone, Debug, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(transparent)]
pub struct JobAddr(pub String);

impl std::fmt::Display for JobAddr {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl JobAddr {
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

// String and str order identically, so map lookups by bare &str are sound.
impl std::borrow::Borrow<str> for JobAddr {
    fn borrow(&self) -> &str {
        &self.0
    }
}

/// A durable run's lifecycle. `lost` is a state like any other: a run whose
/// supervisor is gone without a recorded exit.
#[derive(Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RunState {
    #[default]
    Starting,
    Running,
    Complete,
    Failed,
    Cancelled,
    Lost,
    TimedOut,
}

impl RunState {
    pub fn is_final(self) -> bool {
        !matches!(self, RunState::Starting | RunState::Running)
    }

    /// The wire name, which is also how humans see it: one spelling for
    /// grep, --json, and the terminal.
    fn wire(self) -> &'static str {
        match self {
            RunState::Starting => "starting",
            RunState::Running => "running",
            RunState::Complete => "complete",
            RunState::Failed => "failed",
            RunState::Cancelled => "cancelled",
            RunState::Lost => "lost",
            RunState::TimedOut => "timedOut",
        }
    }

    /// The one exit-code mapping: a completed run succeeds, a failed run
    /// propagates the payload's own code, everything else is a failure.
    pub fn exit(self, exit_code: Option<u8>) -> crate::support::process::CommandStatus {
        use crate::support::process::CommandStatus;
        match self {
            RunState::Complete => CommandStatus::SUCCESS,
            RunState::Failed => exit_code
                .map(CommandStatus::from_code)
                .unwrap_or(CommandStatus::FAILURE),
            _ => CommandStatus::FAILURE,
        }
    }
}

impl std::fmt::Display for RunState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.wire())
    }
}

impl std::fmt::Debug for RunState {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.wire())
    }
}

/// A single build job's outcome.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum JobStatus {
    Pending,
    Success,
    Failure,
}

/// A plan task's outcome, including the renderer-only states.
#[derive(Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TaskStatus {
    Pending,
    Deferred,
    Success,
    Failure,
    Cancelled,
    Skipped,
    Neutral,
}

impl TaskStatus {
    fn wire(self) -> &'static str {
        match self {
            TaskStatus::Pending => "pending",
            TaskStatus::Deferred => "deferred",
            TaskStatus::Success => "success",
            TaskStatus::Failure => "failure",
            TaskStatus::Cancelled => "cancelled",
            TaskStatus::Skipped => "skipped",
            TaskStatus::Neutral => "neutral",
        }
    }
}

impl TaskStatus {
    /// The one failure predicate: the report fold and the process exit both
    /// read it, so a verdict and an exit code cannot disagree.
    pub fn is_failure(self) -> bool {
        matches!(self, TaskStatus::Failure | TaskStatus::Cancelled)
    }

    /// The one mapping from a task's outcome to a process exit: skips,
    /// deferrals, and neutral outcomes are answers.
    pub fn exit(self) -> crate::support::process::CommandStatus {
        use crate::support::process::CommandStatus;
        if self.is_failure() {
            CommandStatus::FAILURE
        } else {
            CommandStatus::SUCCESS
        }
    }
}

impl std::fmt::Display for TaskStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.wire())
    }
}

impl std::fmt::Debug for TaskStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.wire())
    }
}
