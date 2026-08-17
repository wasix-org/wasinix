//! The update run: each target isolated, the repo-wide steps a bump implies,
//! and one ChangeSet describing everything that happened.

use std::path::Path;

use serde_json::Value;

use crate::support::error::{request_error, Result};
use crate::support::process::CommandStatus;
use crate::support::ui;
use crate::update::backends;
use crate::update::changeset::{ChangeSet, Entry, EntryKind, FailedStep, Unchanged};
use crate::update::retention::{self, Versions};
use crate::update::targets::{self, Target};
use crate::update::{select, Mode};

pub struct Options {
    /// Run the package-declared re-syncs and nothing else. They normally run
    /// only when a target moved, which leaves no way to repair a derived
    /// listing that drifted on its own.
    pub hooks_only: bool,
    pub all: bool,
    pub targets: Vec<String>,
    pub commit: bool,
    /// The identity commits carry; None keeps the ambient git config.
    pub committer: Option<crate::support::git::Identity<'static>>,
}

fn repo_status(repo: &Path) -> Result<String> {
    crate::support::git::git_raw(repo, &["status", "--porcelain"])
}

fn changed_files(before: &str, after: &str) -> Vec<String> {
    let prior: std::collections::HashSet<&str> = before.lines().collect();
    after
        .lines()
        .filter(|line| !prior.contains(line))
        .filter_map(|line| line.get(3..))
        .map(str::to_string)
        .collect()
}

fn commit_step(
    repo: &Path,
    message: &str,
    committer: Option<&crate::support::git::Identity<'_>>,
) -> Result<()> {
    crate::support::nix::fmt(repo)?;
    crate::support::git::commit(repo, crate::support::git::Stage::All, message, committer)?;
    Ok(())
}

fn run_retention_hook(repo: &Path, hook: &targets::Hook) -> Result<Option<String>> {
    let name = &hook.name;
    let command = &hook.command;
    ui::fact("hook", name);
    let cmd: Vec<String> = if command[0].contains('/') && !command[0].starts_with('/') {
        let mut cmd = command.to_vec();
        cmd[0] = repo.join(&cmd[0]).to_string_lossy().to_string();
        cmd
    } else {
        command.to_vec()
    };
    backends::realise_command(name, &cmd, &hook.command_drv_paths)?;
    let (code, stdout, stderr) = backends::run_capturing(repo, &cmd, &[])?;
    ui::raw(&stderr);
    backends::echo(&stdout);
    if code != 0 {
        let detail = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        return request_error(format!("{} exited {code}:\n{detail}", command[0]));
    }
    Ok(stdout.trim().lines().last().map(str::to_string))
}

fn hook_stage(
    repo: &Path,
    changes: &mut ChangeSet,
    commit: bool,
    committer: Option<&crate::support::git::Identity<'_>>,
) -> Result<()> {
    for hook in targets::discovered_hooks()? {
        let name = hook.name.clone();
        let before = repo_status(repo)?;
        match run_retention_hook(repo, &hook) {
            Ok(outcome) => {
                let after = repo_status(repo)?;
                // Only a hook that changed something enters the ChangeSet:
                // its no-op line still reaches the log but would be noise in
                // every PR.
                if after != before {
                    let entry = Entry {
                        kind: EntryKind::Hook,
                        subject: name.clone(),
                        from: None,
                        to: None,
                        detail: Some(outcome.unwrap_or_else(|| "re-synced".into())),
                        changelog: None,
                        files: changed_files(&before, &after),
                    };
                    if commit {
                        commit_step(repo, &ChangeSet::commit_message(&entry), committer)?;
                    }
                    changes.entries.push(entry);
                }
            }
            Err(error) => changes.failures.push(FailedStep {
                subject: format!("hook:{name}"),
                message: crate::support::error::brief(&error, 200),
            }),
        }
    }
    Ok(())
}

fn run_hooks(
    repo: &Path,
    commit: bool,
    committer: Option<&crate::support::git::Identity<'_>>,
) -> Result<ChangeSet> {
    let mut changes = ChangeSet::default();
    hook_stage(repo, &mut changes, commit, committer)?;
    Ok(changes)
}

/// A bump entry from a backend's outcome line.
fn bump_entry(target: &Target, outcome: &str, files: Vec<String>) -> Entry {
    let (from, to) = match outcome.split_once(" -> ") {
        Some((from, to)) => (Some(from.to_string()), Some(to.to_string())),
        None => (None, None),
    };
    Entry {
        kind: EntryKind::Bump,
        subject: target.name.clone(),
        detail: (from.is_none()).then(|| outcome.to_string()),
        from,
        to,
        changelog: None,
        files,
    }
}

pub fn drive(repo: &Path, options: Options) -> Result<ChangeSet> {
    let committer = options.committer.as_ref();
    if options.hooks_only {
        return run_hooks(repo, options.commit, committer);
    }
    if options.all && !options.targets.is_empty() {
        return request_error("--all cannot be combined with target arguments");
    }
    if !options.all && options.targets.is_empty() {
        return request_error("update needs --all or at least one target");
    }
    let mut targets = targets::all_targets(repo)?;
    let domain = targets::domain(&targets);
    let (wanted, requests) = select::target_requests(&targets, &domain, &options.targets)?;
    if !options.all {
        targets.retain(|target| wanted.contains(&target.name));
    }

    // Materializing a revision preserves release identity and does not mutate
    // publication state, so the repo-wide steps stay out of its way.
    let release_work = targets.iter().any(|target| {
        requests
            .get(&target.name)
            .is_none_or(|request| request.mode == Mode::Release)
    });
    let priors = if !release_work {
        Value::Null
    } else {
        retention::note_versions()
    };
    // A transient eval failure here must abort: retention diffs against these
    // versions, and starting from an empty map means retaining nothing while
    // the prune still runs.
    let history_priors: Versions = if !release_work {
        Versions::new()
    } else {
        retention::current_versions(repo)?
    };

    // One flaky upstream must not abort the rest: isolate each target,
    // collect failures, and let the caller exit non-zero at the end.
    let mut changes = ChangeSet {
        committed: options.commit,
        ..ChangeSet::default()
    };
    let mut moved: Vec<&Target> = Vec::new();
    for target in &targets {
        ui::fact("target", &target.name);
        let before = repo_status(repo)?;
        match backends::run_backend(repo, target, requests.get(&target.name)) {
            Ok(outcome) => {
                let after = repo_status(repo)?;
                let changed = after != before;
                let outcome = outcome
                    .unwrap_or_else(|| if changed { "updated" } else { "up to date" }.to_string());
                let outcome = backends::normalize_outcome(target, outcome, changed);
                if changed {
                    let entry = bump_entry(target, &outcome, changed_files(&before, &after));
                    if options.commit {
                        commit_step(repo, &ChangeSet::commit_message(&entry), committer)?;
                    }
                    changes.entries.push(entry);
                    moved.push(target);
                } else {
                    changes.unchanged.push(Unchanged {
                        subject: target.name.clone(),
                        detail: outcome,
                    });
                }
            }
            Err(error) => {
                changes.failures.push(FailedStep {
                    subject: target.name.clone(),
                    message: crate::support::error::brief(&error, 200),
                });
            }
        }
    }

    // Changelogs in one evaluation after the bumps, so each url names the
    // release that actually landed.
    let links = backends::changelogs(&moved);
    for entry in &mut changes.entries {
        if entry.kind == EntryKind::Bump {
            entry.changelog = links.get(&entry.subject).cloned();
        }
    }

    // Retain before pruning: the prune drops the rel key of any version no
    // longer served, which is exactly what retention just brought back.
    if changes.changed() && release_work {
        match retention::regen_history(repo, &history_priors) {
            Ok(Some(retained)) => {
                let entry = Entry {
                    kind: EntryKind::Retain,
                    subject: "history".into(),
                    from: None,
                    to: None,
                    detail: Some(retained),
                    changelog: None,
                    files: Vec::new(),
                };
                if options.commit {
                    commit_step(repo, &ChangeSet::commit_message(&entry), committer)?;
                }
                changes.entries.push(entry);
            }
            Ok(None) => {}
            Err(error) => changes.failures.push(FailedStep {
                subject: "history retention".into(),
                message: crate::support::error::brief(&error, 300),
            }),
        }
    }
    if release_work {
        match retention::prune_rels(repo) {
            Ok(Some(pruned)) => {
                let entry = Entry {
                    kind: EntryKind::Prune,
                    subject: "rels".into(),
                    from: None,
                    to: None,
                    detail: Some(pruned),
                    changelog: None,
                    files: Vec::new(),
                };
                if options.commit {
                    commit_step(repo, &ChangeSet::commit_message(&entry), committer)?;
                }
                changes.entries.push(entry);
            }
            Ok(None) => {}
            Err(error) => changes.failures.push(FailedStep {
                subject: "rels prune".into(),
                message: crate::support::error::brief(&error, 300),
            }),
        }
    }

    // Package-declared re-syncs last: a hook regenerates a listing derived
    // from the pins once history and the prune have settled.
    if changes.changed() && release_work {
        hook_stage(repo, &mut changes, options.commit, committer)?;
    }

    if release_work {
        for note in retention::fired_notes(repo, &priors) {
            changes.entries.push(Entry {
                kind: EntryKind::Notable,
                subject: note.name.clone(),
                from: note.prior.clone(),
                to: note.version.clone(),
                detail: Some(note.message.clone()),
                changelog: None,
                files: Vec::new(),
            });
        }
    }
    Ok(changes)
}

pub fn exit_of(changes: &ChangeSet) -> CommandStatus {
    if changes.failures.is_empty() {
        CommandStatus::SUCCESS
    } else {
        CommandStatus::FAILURE
    }
}
