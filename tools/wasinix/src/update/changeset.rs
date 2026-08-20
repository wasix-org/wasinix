//! The one mutation document. Every mutating verb produces a ChangeSet, and
//! every rendering of a mutation (terminal receipt, commit messages, PR body,
//! reply comment) reads it, so they cannot tell different stories.

use serde::{Deserialize, Serialize};

use crate::support::schema::Document;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EntryKind {
    /// A pin moved to a new version or revision.
    Bump,
    /// An outgoing version kept behind in the registry history.
    Retain,
    /// A publication release counter bumped.
    Rel,
    /// Stale publication keys dropped.
    Prune,
    /// An older version added to the registry history.
    Backfill,
    /// A derived listing re-synced.
    Hook,
    /// The tree reformatted by the repo's formatter.
    Format,
    /// An advisory note surfaced by the run, never a file change.
    Notable,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub kind: EntryKind,
    pub subject: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<String>,
    /// One line of what happened when from/to do not carry it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub changelog: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub files: Vec<String>,
}

/// A target that ran and did not change anything, with what it is current at.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Unchanged {
    pub subject: String,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FailedStep {
    pub subject: String,
    pub message: String,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangeSet {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub entries: Vec<Entry>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub unchanged: Vec<Unchanged>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub failures: Vec<FailedStep>,
    /// Whether the working tree still carries the changes uncommitted.
    #[serde(default)]
    pub committed: bool,
}

impl Document for ChangeSet {
    const KIND: &'static str = "changeSet";
    const SCHEMA: u32 = 1;
}

impl ChangeSet {
    pub fn changed(&self) -> bool {
        self.entries
            .iter()
            .any(|entry| entry.kind != EntryKind::Notable)
    }

    /// The commit message one entry lands as, in the repo's voice.
    pub fn commit_message(entry: &Entry) -> String {
        match entry.kind {
            EntryKind::Bump => match (&entry.from, &entry.to) {
                (Some(from), Some(to)) => format!("{}: {from} -> {to}", entry.subject),
                (None, Some(to)) => format!("{}: update to {to}", entry.subject),
                _ => format!("{}: update", entry.subject),
            },
            EntryKind::Retain => "pkgs: retain outgoing versions in registry history".into(),
            EntryKind::Rel => match (&entry.from, &entry.to) {
                (Some(from), Some(to)) => {
                    format!(
                        "pkgs: bump {} rel wasix.{from} to wasix.{to}",
                        entry.subject
                    )
                }
                _ => format!("pkgs: bump {} rel", entry.subject),
            },
            EntryKind::Backfill => match &entry.to {
                Some(version) => format!("pkgs: backfill {} {version}", entry.subject),
                None => format!("pkgs: backfill {}", entry.subject),
            },
            EntryKind::Prune => "pkgs: prune rels keys nothing serves".into(),
            EntryKind::Hook => format!("{}: re-sync generated listing", entry.subject),
            EntryKind::Format => "treewide: apply the repo formatter".into(),
            EntryKind::Notable => format!("{}: note", entry.subject),
        }
    }

    /// The PR title a mutation defaults to when its verb has no fixed one:
    /// the sole bump's commit message, or the bumped targets.
    pub fn title(&self) -> String {
        let bumps: Vec<&Entry> = self
            .entries
            .iter()
            .filter(|entry| entry.kind == EntryKind::Bump)
            .collect();
        match bumps.as_slice() {
            [only] => ChangeSet::commit_message(only),
            [] => "pins: automated update".to_string(),
            many => format!(
                "pins: bump {}",
                many.iter()
                    .map(|entry| entry.subject.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        }
    }

    /// The terminal receipt: one line per item with its outcome, ending with
    /// what changed on disk.
    pub fn receipt(&self) -> Vec<String> {
        let mut lines = Vec::new();
        for entry in &self.entries {
            let glyph = match entry.kind {
                EntryKind::Hook => "▸",
                EntryKind::Notable => "ℹ",
                _ => "✓",
            };
            let mut parts = vec![match (&entry.from, &entry.to) {
                (Some(from), Some(to)) => format!("{glyph} {}  {from} → {to}", entry.subject),
                (None, Some(to)) => format!("{glyph} {}  {to}", entry.subject),
                _ => format!("{glyph} {}", entry.subject),
            }];
            if let Some(detail) = &entry.detail {
                parts.push(detail.clone());
            }
            if let Some(changelog) = &entry.changelog {
                parts.push(format!("changelog: {changelog}"));
            }
            lines.push(parts.join(" · "));
        }
        for unchanged in &self.unchanged {
            lines.push(format!("· {}  {}", unchanged.subject, unchanged.detail));
        }
        for failure in &self.failures {
            lines.push(format!("✗ {}  {}", failure.subject, failure.message));
        }
        let moved = self
            .entries
            .iter()
            .filter(|entry| entry.kind == EntryKind::Bump)
            .count();
        let mut summary = vec![
            format!("{moved} updated"),
            format!("{} failed", self.failures.len()),
        ];
        summary.push(if !self.changed() {
            "tree unchanged".to_string()
        } else if self.committed {
            "committed".to_string()
        } else {
            "tree modified, not committed".to_string()
        });
        lines.push(crate::support::ui::counts(&summary));
        lines
    }
}
