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
use crate::update::targets::{self, PostUpdateHook, Target};
use crate::update::{select, Mode};

pub struct Options {
    /// Run the package-declared re-syncs and nothing else. They normally run
    /// only when their package version moves, which leaves no way to repair a
    /// derived listing that drifted on its own.
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

fn post_update_command(
    repo: &Path,
    command: &[String],
    versions: Option<(&str, &str)>,
) -> Vec<String> {
    let mut cmd = if command[0].contains('/') && !command[0].starts_with('/') {
        let mut cmd = command.to_vec();
        cmd[0] = repo.join(&cmd[0]).to_string_lossy().to_string();
        cmd
    } else {
        command.to_vec()
    };
    if let Some((prior, current)) = versions {
        cmd.extend([prior.to_string(), current.to_string()]);
    }
    cmd
}

fn run_post_update_hook(
    repo: &Path,
    hook: &PostUpdateHook,
    versions: Option<(&str, &str)>,
) -> Result<Option<String>> {
    ui::fact("hook", &hook.name);
    let cmd = post_update_command(repo, &hook.command, versions);
    backends::realise_command(&hook.name, &cmd, &hook.command_drv_paths)?;
    let (code, stdout, stderr) = backends::run_capturing(repo, &cmd, &[])?;
    ui::raw(&stderr);
    backends::echo(&stdout);
    if code != 0 {
        let detail = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        return request_error(format!("{} exited {code}:\n{detail}", hook.command[0]));
    }
    Ok(stdout.trim().lines().last().map(str::to_string))
}

fn changed_hooks(
    prior: &[PostUpdateHook],
    current: Vec<PostUpdateHook>,
) -> Vec<(PostUpdateHook, String)> {
    let prior_versions: std::collections::BTreeMap<&str, &str> = prior
        .iter()
        .map(|hook| (hook.name.as_str(), hook.version.as_str()))
        .collect();
    current
        .into_iter()
        .filter_map(|hook| {
            let prior = prior_versions.get(hook.name.as_str())?;
            (*prior != hook.version).then(|| (hook, (*prior).to_string()))
        })
        .collect()
}

fn hook_stage(
    repo: &Path,
    changes: &mut ChangeSet,
    commit: bool,
    committer: Option<&crate::support::git::Identity<'_>>,
    hooks: Vec<(PostUpdateHook, Option<String>)>,
) -> Result<()> {
    for (hook, prior) in hooks {
        let before = repo_status(repo)?;
        let versions = prior.as_deref().map(|prior| (prior, hook.version.as_str()));
        match run_post_update_hook(repo, &hook, versions) {
            Ok(outcome) => {
                let after = repo_status(repo)?;
                // Only a hook that changed something enters the ChangeSet:
                // its no-op line still reaches the log but would be noise in
                // every PR.
                if after != before {
                    let entry = Entry {
                        kind: EntryKind::Hook,
                        subject: hook.name.clone(),
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
                subject: format!("hook:{}", hook.name),
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
    let hooks = targets::discovered_post_update_hooks()?
        .into_iter()
        .map(|hook| (hook, None))
        .collect();
    hook_stage(repo, &mut changes, commit, committer, hooks)?;
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
    let prior_hooks = targets::discovered_post_update_hooks()?;
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
        let started = std::time::Instant::now();
        let before = repo_status(repo)?;
        let outcome = backends::run_backend(repo, target, requests.get(&target.name));
        ui::note(format!(
            "  took {}",
            crate::support::format::duration(started.elapsed().as_secs_f64())
        ));
        match outcome {
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

    // Package-declared re-syncs last, after any release-only history work.
    if changes.changed() {
        let hooks = changed_hooks(&prior_hooks, targets::discovered_post_update_hooks()?)
            .into_iter()
            .map(|(hook, prior)| (hook, Some(prior)))
            .collect();
        hook_stage(repo, &mut changes, options.commit, committer, hooks)?;
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

#[cfg(test)]
mod tests {
    use super::*;

    fn hook(name: &str, command: &str, version: &str) -> PostUpdateHook {
        PostUpdateHook {
            name: name.into(),
            command: vec![command.into()],
            command_drv_paths: Vec::new(),
            version: version.into(),
        }
    }

    #[test]
    fn automatic_hooks_run_only_for_changed_package_versions() {
        let prior = vec![hook("same", "same.py", "1"), hook("moved", "old.py", "1")];
        let current = vec![hook("same", "same.py", "1"), hook("moved", "new.py", "2")];
        assert_eq!(
            changed_hooks(&prior, current),
            vec![(hook("moved", "new.py", "2"), "1".into())]
        );
    }

    #[test]
    fn hooks_without_a_prior_declaration_do_not_run_automatically() {
        assert!(changed_hooks(&[], vec![hook("new", "new.py", "1")]).is_empty());
    }

    #[test]
    fn automatic_hooks_receive_the_old_and_new_versions() {
        assert_eq!(
            post_update_command(
                Path::new("/repo"),
                &["hook".into(), "--flag".into()],
                Some(("1", "2"))
            ),
            ["hook", "--flag", "1", "2"]
        );
    }
}
