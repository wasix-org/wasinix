//! The markdown a ChangeSet renders to: the PR body, and the `/wasinix`
//! reply receipt. Both read the same document the terminal receipt does, so a
//! PR and its CI comment agree by construction.

use crate::github::sanitize::Markdown;
use crate::update::changeset::{ChangeSet, Entry, EntryKind};

const TABLE_ROWS: usize = 100;
/// PR bodies stay scannable; the run log holds the full story.
pub const PR_BODY_BUDGET: usize = 20_000;

/// The managed footer, stating the contract for a bot-owned branch.
const MANAGED_FOOTER: &str = "\n---\n<sub>Managed by wasinix: pushing to this \
    branch pauses automated refreshes; `/wasinix update` refreshes it.</sub>\n";

fn bump_rows(entries: &[&Entry]) -> Markdown {
    let mut table = Markdown::constant("| target | from | to | changelog |\n|:--|:--|:--|:--|\n");
    for entry in entries.iter().take(TABLE_ROWS) {
        let changelog = match entry.changelog.as_deref() {
            Some(url) => Markdown::cell_link("changelog", url),
            None => Markdown::new(),
        };
        table = Markdown::concat([
            table,
            Markdown::constant("| "),
            Markdown::cell(&entry.subject),
            Markdown::constant(" | "),
            Markdown::cell(entry.from.as_deref().unwrap_or("")),
            Markdown::constant(" | "),
            Markdown::cell(entry.to.as_deref().unwrap_or("")),
            Markdown::constant(" | "),
            changelog,
            Markdown::constant(" |\n"),
        ]);
    }
    if entries.len() > TABLE_ROWS {
        table = Markdown::concat([
            table,
            Markdown::constant("\nand "),
            Markdown::text(&(entries.len() - TABLE_ROWS).to_string()),
            Markdown::constant(" more, see the run\n"),
        ]);
    }
    table
}

fn of_kind(changes: &ChangeSet, kind: EntryKind) -> Vec<&Entry> {
    changes
        .entries
        .iter()
        .filter(|entry| entry.kind == kind)
        .collect()
}

fn notes_block(changes: &ChangeSet) -> Markdown {
    let notes = of_kind(changes, EntryKind::Notable);
    if notes.is_empty() {
        return Markdown::new();
    }
    let mut block = Markdown::new();
    for note in notes {
        let moved = match (&note.from, &note.to) {
            (Some(from), Some(to)) => Markdown::concat([
                Markdown::constant(" ("),
                Markdown::text(from),
                Markdown::constant(" → "),
                Markdown::text(to),
                Markdown::constant(")"),
            ]),
            _ => Markdown::new(),
        };
        block = Markdown::concat([
            block,
            Markdown::constant("\n> [!NOTE]\n> **"),
            Markdown::text(&note.subject),
            Markdown::constant("**"),
            moved,
            Markdown::constant(": "),
            Markdown::text(note.detail.as_deref().unwrap_or("")),
            Markdown::constant("\n"),
        ]);
    }
    block
}

fn secondary_details(changes: &ChangeSet) -> Markdown {
    let mut lines = Vec::new();
    for entry in &changes.entries {
        match entry.kind {
            EntryKind::Retain | EntryKind::Prune | EntryKind::Hook => {
                lines.push(Markdown::concat([
                    Markdown::constant("- **"),
                    Markdown::text(&entry.subject),
                    Markdown::constant("**: "),
                    Markdown::text(entry.detail.as_deref().unwrap_or("")),
                ]));
            }
            _ => {}
        }
    }
    if lines.is_empty() {
        return Markdown::new();
    }
    Markdown::concat([
        Markdown::constant("\n<details><summary>Retention, prune, and hooks ("),
        Markdown::text(&lines.len().to_string()),
        Markdown::constant(")</summary>\n\n"),
        Markdown::join(lines, "\n"),
        Markdown::constant("\n\n</details>\n"),
    ])
}

/// The update PR body. `managed` adds the bot-branch footer; a human's fork PR
/// carries the same body without it, so the bot never force-pushes over it.
pub fn pr_body(changes: &ChangeSet, managed: bool) -> Markdown {
    let mut body = Markdown::constant("### Automated pin update\n\n");
    body = body.push(sections(changes));
    if managed {
        body = body.push(Markdown::constant(MANAGED_FOOTER));
    }
    body
}

/// The `/wasinix` mutation reply: the same sections under the outcome
/// heading, plus the branch head the PR now sits at.
pub fn reply(changes: &ChangeSet, heading: &'static str, head_sha: &str) -> Markdown {
    Markdown::concat([
        Markdown::constant(heading),
        Markdown::constant("\n\n"),
        sections(changes),
        Markdown::constant("\nBranch head: "),
        Markdown::code(head_sha),
        Markdown::constant("\n"),
    ])
}

fn sections(changes: &ChangeSet) -> Markdown {
    let bumps = of_kind(changes, EntryKind::Bump);
    let rels = of_kind(changes, EntryKind::Rel);
    let mut body = Markdown::new();
    if bumps.is_empty() && rels.is_empty() {
        body = body.push(Markdown::constant("No pins moved.\n"));
    }
    if !bumps.is_empty() {
        body = body.push(bump_rows(&bumps));
    }
    if !rels.is_empty() {
        body = body.push(Markdown::constant(
            "\n**Publication releases**\n\n| package | to |\n|:--|:--|\n",
        ));
        for entry in &rels {
            body = Markdown::concat([
                body,
                Markdown::constant("| "),
                Markdown::cell(&entry.subject),
                Markdown::constant(" | wasix."),
                Markdown::cell(entry.to.as_deref().unwrap_or("")),
                Markdown::constant(" |\n"),
            ]);
        }
    }
    let backfills = of_kind(changes, EntryKind::Backfill);
    if !backfills.is_empty() {
        body = body.push(Markdown::constant(
            "\n**Version backfills**\n\n| package | version | detail |\n|:--|:--|:--|\n",
        ));
        for entry in &backfills {
            body = Markdown::concat([
                body,
                Markdown::constant("| "),
                Markdown::cell(&entry.subject),
                Markdown::constant(" | "),
                Markdown::cell(entry.to.as_deref().unwrap_or("")),
                Markdown::constant(" | "),
                Markdown::cell(entry.detail.as_deref().unwrap_or("")),
                Markdown::constant(" |\n"),
            ]);
        }
    }
    body = body.push(notes_block(changes));
    body = body.push(secondary_details(changes));
    if !changes.failures.is_empty() {
        body = Markdown::concat([
            body,
            Markdown::constant("\n> [!WARNING]\n> "),
            Markdown::text(&changes.failures.len().to_string()),
            Markdown::constant(" step(s) failed; this update is incomplete.\n"),
        ]);
    }
    body
}
