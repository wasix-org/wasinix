//! The update run: each target isolated, the repo-wide steps a bump implies,
//! and one ChangeSet describing everything that happened.

use std::path::Path;

use serde_json::Value;

use crate::support::error::{Result, request_error};
use crate::support::process::CommandStatus;
use crate::support::ui;
use crate::update::backends;
use crate::update::changeset::{ChangeSet, Entry, EntryKind, FailedStep, Unchanged};
use crate::update::retention::{self, Versions};
use crate::update::targets::{self, PostUpdateAction, PostUpdateHook, Target};
use crate::update::{Mode, select};

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
    pub preflight: Option<Preflight>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Preflight {
    revision: String,
    release_priors: bool,
    targets: Vec<Target>,
    prior_hooks: Vec<PostUpdateHook>,
    priors: Value,
    history_priors: Versions,
}

impl crate::support::schema::Document for Preflight {
    const KIND: &'static str = "updatePreflight";
    const SCHEMA: u32 = 1;
}

impl Preflight {
    pub fn collect(
        repo: &Path,
        targets: Vec<Target>,
        snapshot: &crate::update::snapshot::Snapshot,
        release_work: bool,
    ) -> Result<Preflight> {
        let revision = crate::support::git::git(repo, &["rev-parse", "HEAD"])?;
        let prior_hooks = targets::discovered_post_update_hooks(&snapshot.post_update_hooks)?;
        let (priors, history_priors) = if release_work {
            if !snapshot.notes.ok {
                ui::warning("note version eval failed");
            }
            (
                snapshot.notes.value.clone(),
                snapshot.served_versions.clone(),
            )
        } else {
            (Value::Null, Versions::new())
        };
        Ok(Preflight {
            revision,
            release_priors: release_work,
            targets,
            prior_hooks,
            priors,
            history_priors,
        })
    }

    fn validate(&self, repo: &Path) -> Result<()> {
        let revision = crate::support::git::git(repo, &["rev-parse", "HEAD"])?;
        if revision != self.revision {
            return request_error(format!(
                "update preflight is for {}, worker is at {revision}",
                self.revision
            ));
        }
        Ok(())
    }
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
    match &hook.action {
        PostUpdateAction::Command {
            command,
            command_drv_paths,
        } => {
            let cmd = post_update_command(repo, command, versions);
            backends::realise_command(&hook.name, &cmd, command_drv_paths)?;
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
        PostUpdateAction::SyncAttrList(spec) => {
            let outcome = crate::update::sync::run(repo, spec)?;
            ui::result(&outcome.detail);
            Ok(Some(outcome.detail))
        }
    }
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

fn release_followups(changes: &ChangeSet, release_work: bool) -> bool {
    release_work && changes.changed()
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
    let snapshot = crate::update::snapshot::load(repo)?;
    let hooks = targets::discovered_post_update_hooks(&snapshot.post_update_hooks)?
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
    let preflight = match options.preflight {
        Some(preflight) => preflight,
        None => {
            let snapshot = crate::update::snapshot::load(repo)?;
            let targets = targets::all_targets(repo, &snapshot)?;
            Preflight::collect(repo, targets, &snapshot, true)?
        }
    };
    preflight.validate(repo)?;
    let prior_hooks = preflight.prior_hooks;
    let mut targets = preflight.targets;
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
    // A transient eval failure here must abort: retention diffs against these
    // versions, and starting from an empty map means retaining nothing while
    // the prune still runs. Both views come from one package-set evaluation.
    if release_work && !preflight.release_priors {
        return request_error("update preflight carries no release priors");
    }
    let (priors, history_priors) = if release_work {
        (preflight.priors, preflight.history_priors)
    } else {
        (Value::Null, Versions::new())
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

    let release_changed = release_followups(&changes, release_work);
    let current_snapshot = if changes.changed() {
        Some(crate::update::snapshot::evaluate(repo)?)
    } else {
        None
    };

    // Retain before pruning: the prune drops the rel key of any version no
    // longer served, which is exactly what retention just brought back.
    if release_changed {
        match retention::regen_history(
            repo,
            &history_priors,
            &current_snapshot
                .as_ref()
                .expect("a release change has current update state")
                .served_versions,
        ) {
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
    if release_changed {
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
        let hooks = changed_hooks(
            &prior_hooks,
            targets::discovered_post_update_hooks(
                &current_snapshot
                    .as_ref()
                    .expect("changed updates have current update state")
                    .post_update_hooks,
            )?,
        )
        .into_iter()
        .map(|(hook, prior)| (hook, Some(prior)))
        .collect();
        hook_stage(repo, &mut changes, options.commit, committer, hooks)?;
    }

    if release_changed {
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
            action: PostUpdateAction::Command {
                command: vec![command.into()],
                command_drv_paths: Vec::new(),
            },
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

    #[test]
    fn release_followups_require_a_changed_release_target() {
        let mut changes = ChangeSet::default();
        assert!(!release_followups(&changes, true));
        changes.entries.push(Entry {
            kind: EntryKind::Bump,
            subject: "pkg".into(),
            from: Some("1".into()),
            to: Some("2".into()),
            detail: None,
            changelog: None,
            files: Vec::new(),
        });
        assert!(release_followups(&changes, true));
        assert!(!release_followups(&changes, false));
    }
}
