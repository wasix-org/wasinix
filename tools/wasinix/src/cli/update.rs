//! The update verb and the versions noun. Every mutating arm flattens
//! [`MutationMode`] and leaves through [`conclude`], so commits, PRs,
//! receipts, JSON, and exit codes cannot diverge between arms.

use std::path::{Path, PathBuf};

use crate::support::error::{Result, request_error};
use crate::support::process::CommandStatus;
use crate::support::{schema, table, ui};
use crate::update::changeset::{ChangeSet, Entry, EntryKind, Unchanged};
use crate::update::{drive, history, rels, targets, timing};

/// How a mutation leaves the tree; every mutating arm carries these flags.
#[derive(clap::Args)]
pub struct MutationMode {
    /// Commit each change as it lands
    #[arg(long)]
    pub commit: bool,
    /// Open (or update) a pull request with the changes; implies --commit
    #[arg(long)]
    pub pr: bool,
    /// The PR branch; each verb has a default
    #[arg(long)]
    pub branch: Option<String>,
    /// OWNER/REPO for the PR; $GITHUB_REPOSITORY, then the checkout's
    /// origin, when absent
    #[arg(long)]
    pub repository: Option<String>,
    /// The base branch the PR targets
    #[arg(long, default_value = "main")]
    pub base: String,
    /// A human's fork PR: no managed footer, never force-pushed
    #[arg(long)]
    pub fork: bool,
    #[command(flatten)]
    pub json: ui::JsonArg,
}

impl MutationMode {
    pub fn commits(&self) -> bool {
        self.commit || self.pr
    }

    /// Managed-branch commits carry the bot identity, so workflows need no
    /// git-config step; a fork PR keeps the human's ambient config.
    pub fn committer(&self) -> Option<crate::support::git::Identity<'static>> {
        (self.pr && !self.fork).then_some(crate::support::git::Identity {
            name: crate::github::surfaces::BOT_AUTHOR,
            email: crate::github::surfaces::BOT_EMAIL,
        })
    }
}

/// What the PR looks like when this verb opens one.
struct PrShape {
    /// The branch when --branch is absent; None makes --pr demand --branch.
    branch: Option<String>,
    /// The PR title; None derives it from the ChangeSet.
    title: Option<String>,
    /// The comment that replays this branch; None for an arm no comment can
    /// spell, whose PR then advertises no refresh.
    recipe: Option<String>,
    ownership: targets::Ownership,
}

/// The one mutation exit: PR upsert when asked, then the receipt or the
/// ChangeSet document, then the exit code, identically for every arm.
fn conclude(
    repo: &Path,
    changes: &ChangeSet,
    mode: &MutationMode,
    shape: PrShape,
    timings: Option<&mut timing::Recorder>,
) -> Result<CommandStatus> {
    if mode.pr && changes.changed() {
        let repository =
            crate::github::surfaces::resolve_repository(mode.repository.as_deref(), repo)?;
        let branch = mode.branch.clone().or(shape.branch).ok_or_else(|| {
            crate::support::error::Error::Request(
                "--pr needs a target or --branch to name the branch".into(),
            )
        })?;
        let title = shape.title.unwrap_or_else(|| changes.title());
        let options = crate::github::mutation::PrOptions {
            repository,
            branch,
            title,
            base: mode.base.clone(),
            managed: !mode.fork,
            recipe: shape.recipe,
            ownership: shape.ownership,
        };
        let open = || crate::github::mutation::open_pr(repo, changes, &options);
        let number = match timings {
            Some(timings) => timings.measure(timing::Phase::PullRequest, open)?,
            None => open()?,
        };
        ui::fact("pull request", number);
    }
    ui::emit(&mode.json, changes, |changes| {
        for line in changes.receipt() {
            ui::result(line);
        }
    })?;
    Ok(drive::exit_of(changes))
}

#[derive(clap::Args)]
pub struct UpdateArgs {
    /// Targets (TARGET, TARGET@VERSION, TARGET@tag:NAME, TARGET@rev:SHA); `list` shows them,
    /// `hooks` runs only the re-sync hooks. For package update scripts:
    /// `request` prints the driver's request, `nix-update -- <argv>` runs a
    /// declared nix-update command with the request applied
    #[arg(add = clap_complete::ArgValueCandidates::new(target_candidates))]
    pub targets: Vec<String>,
    /// Update every target
    #[arg(long, conflicts_with = "targets")]
    pub all: bool,
    /// Maximum update PRs running at once
    #[arg(long, default_value = "2")]
    pub jobs: std::num::NonZeroUsize,
    /// Shared batch state prepared by the parent update process
    #[arg(long, hide = true)]
    pub batch_preflight: Option<PathBuf>,
    /// Worker timing sidecar collected by the parent update process
    #[arg(long, hide = true)]
    pub batch_timings: Option<PathBuf>,
    /// Append aggregate update timings to a GitHub step summary
    #[arg(long, hide = true)]
    pub step_summary: Option<PathBuf>,
    /// With `request`: fail unless the request targets this name
    #[arg(long, value_name = "NAME")]
    pub expect: Option<String>,
    #[command(flatten)]
    pub mode: MutationMode,
}

#[derive(clap::Subcommand)]
pub enum VersionsCommand {
    /// Add older versions of a shipped package to the registry history
    Add {
        /// The package, as NAME, NAME@VERSION, or an address
        spec: String,
        /// Add the latest release of every major series older than the pin
        #[arg(long, conflicts_with = "per_minor")]
        per_major: bool,
        /// Add the latest release of every minor series older than the pin
        #[arg(long)]
        per_minor: bool,
        /// Ignore series older than this version in bulk mode
        #[arg(long)]
        since: Option<String>,
        /// The upstream project name when it differs from the attr
        #[arg(long)]
        project: Option<String>,
        /// Limit the entry to these build variants (comma-separated)
        #[arg(long, value_delimiter = ',')]
        variants: Vec<String>,
        /// A note recorded on the entry
        #[arg(long)]
        note: Option<String>,
        /// Add even when upstream ships no wheels for our interpreters
        #[arg(long)]
        force: bool,
        #[arg(long, conflicts_with_all = ["commit", "pr"])]
        dry_run: bool,
        #[command(flatten)]
        mode: MutationMode,
    },
    /// Import a lockfile's pins of shipped packages into the history
    Import {
        lockfile: PathBuf,
        #[arg(long, conflicts_with_all = ["commit", "pr"])]
        dry_run: bool,
        #[command(flatten)]
        mode: MutationMode,
    },
    /// Bump publication release counters (+wasix.N)
    Bump {
        /// Packages, optionally @<version>
        #[arg(required_unless_present_any = ["changed_from", "changed"])]
        specs: Vec<String>,
        /// Bump every version a package serves, not just its only one
        #[arg(long)]
        all_versions: bool,
        /// Select served versions whose publication derivations changed from REF
        #[arg(long, value_name = "REF", conflicts_with_all = ["specs", "all_versions"])]
        changed_from: Option<String>,
        /// Select versions changed from the verified pull request base
        #[arg(long, conflicts_with_all = ["specs", "all_versions", "changed_from"])]
        changed: bool,
        #[command(flatten)]
        mode: MutationMode,
    },
}

/// Completion values for update targets: the verbs, then the target names
/// as of the last discovery this machine ran.
fn target_candidates() -> Vec<clap_complete::CompletionCandidate> {
    ["list", "hooks"]
        .into_iter()
        .map(str::to_string)
        .chain(crate::support::completions::recall("update-targets"))
        .map(clap_complete::CompletionCandidate::new)
        .collect()
}

pub fn run_update(args: UpdateArgs) -> Result<CommandStatus> {
    let repo = crate::support::git::repo_root()?;
    if args.expect.is_some() && args.targets.first().map(String::as_str) != Some("request") {
        return request_error("--expect only applies to `update request`");
    }
    match args.targets.first().map(String::as_str) {
        Some("request") if args.targets.len() == 1 => {
            let request = crate::update::request::current(args.expect.as_deref())?;
            ui::output(match request {
                Some(request) => serde_json::to_string(&request).map_err(|source| {
                    crate::support::error::Error::Json {
                        path: format!("<{}>", crate::update::REQUEST_ENV).into(),
                        source,
                    }
                })?,
                None => "{}".to_string(),
            });
            Ok(CommandStatus::SUCCESS)
        }
        Some("nix-update") => {
            let code = crate::update::backends::run_nix_update(&repo, &args.targets[1..])?;
            Ok(CommandStatus::from_code(code.clamp(0, 255) as u8))
        }
        Some("list") if args.targets.len() == 1 => {
            let snapshot = crate::update::snapshot::load(&repo)?;
            let targets = targets::all_targets(&repo, &snapshot)?;
            #[derive(serde::Serialize, serde::Deserialize)]
            struct UpdateTargets {
                targets: Vec<String>,
            }
            impl schema::Document for UpdateTargets {
                const KIND: &'static str = "updateTargets";
                const SCHEMA: u32 = 1;
            }
            ui::emit(
                &args.mode.json,
                &UpdateTargets {
                    targets: targets.iter().map(|t| t.name.clone()).collect(),
                },
                |_| {
                    let rows: Vec<Vec<String>> = targets
                        .iter()
                        .map(|target| {
                            vec![
                                target.name.clone(),
                                target.backend_name().to_string(),
                                target.detail(),
                            ]
                        })
                        .collect();
                    ui::output(table::render(
                        Some(&["target", "backend", "command"]),
                        &rows,
                    ));
                },
            )?;
            Ok(CommandStatus::SUCCESS)
        }
        Some("hooks") if args.targets.len() == 1 => {
            let changes = drive::drive(
                &repo,
                drive::Options {
                    hooks_only: true,
                    all: false,
                    targets: Vec::new(),
                    commit: args.mode.commits(),
                    committer: args.mode.committer(),
                    preflight: None,
                },
            )?;
            conclude(
                &repo,
                &changes,
                &args.mode,
                PrShape {
                    branch: None,
                    title: None,
                    recipe: None,
                    ownership: targets::Ownership::default(),
                },
                None,
            )
        }
        _ => {
            if args.mode.pr && args.batch_preflight.is_none() {
                let report = crate::update::batch::run(
                    &repo,
                    args.all,
                    &args.targets,
                    crate::update::batch::Options {
                        jobs: args.jobs.get(),
                        repository: args.mode.repository.clone(),
                        base: args.mode.base.clone(),
                        branch: args.mode.branch.clone(),
                        fork: args.mode.fork,
                    },
                )?;
                if let Some(path) = &args.step_summary {
                    report.append_step_summary(path)?;
                }
                ui::emit(
                    &args.mode.json,
                    &report,
                    crate::update::batch::Report::render,
                )?;
                return Ok(report.status());
            }
            let branch = args
                .targets
                .first()
                .map(|first| format!("auto/update-{first}"));
            let title = args
                .all
                .then(|| "pins: automated source-pin bump".to_string());
            let recipe = args.comment_recipe();
            let preflight: Option<drive::Preflight> = args
                .batch_preflight
                .as_deref()
                .map(schema::read)
                .transpose()?;
            let ownership = preflight
                .as_ref()
                .and_then(|preflight| {
                    args.targets
                        .first()
                        .map(|spec| preflight.ownership_for(spec))
                })
                .unwrap_or_default();
            let mut timings = timing::Recorder::new(args.batch_timings);
            let changes = drive::drive_timed(
                &repo,
                drive::Options {
                    hooks_only: false,
                    all: args.all,
                    targets: args.targets,
                    commit: args.mode.commits(),
                    committer: args.mode.committer(),
                    preflight,
                },
                &mut timings,
            );
            let status = changes.and_then(|changes| {
                conclude(
                    &repo,
                    &changes,
                    &args.mode,
                    PrShape {
                        branch,
                        title,
                        recipe,
                        ownership,
                    },
                    Some(&mut timings),
                )
            });
            let timing_status = timings.finish();
            match (status, timing_status) {
                (Ok(status), Ok(())) => Ok(status),
                (Err(error), _) | (Ok(_), Err(error)) => Err(error),
            }
        }
    }
}

/// The ChangeSet a backfill run produces: one entry per added version, one
/// unchanged line per version already covered or skipped.
fn backfill_changes(
    outcomes: Vec<(String, String, history::AddOutcome)>,
    committed: bool,
) -> ChangeSet {
    let mut changes = ChangeSet {
        committed,
        ..ChangeSet::default()
    };
    for (attr, version, outcome) in outcomes {
        match outcome {
            history::AddOutcome::Added { detail } => changes.entries.push(Entry {
                kind: EntryKind::Backfill,
                subject: attr,
                from: None,
                to: Some(version),
                detail: Some(format!("added{detail}")),
                changelog: None,
                files: Vec::new(),
            }),
            history::AddOutcome::AlreadyPresent => changes.unchanged.push(Unchanged {
                subject: format!("{attr}@{version}"),
                detail: "already in history.json".into(),
            }),
            history::AddOutcome::CurrentVersion => changes.unchanged.push(Unchanged {
                subject: format!("{attr}@{version}"),
                detail: "is the current version".into(),
            }),
            history::AddOutcome::Skipped { reason } => changes.unchanged.push(Unchanged {
                subject: format!("{attr}@{version}"),
                detail: format!("{reason}; skipped"),
            }),
        }
    }
    changes
}

/// Commit a backfill as one commit over exactly the touched history tables.
fn commit_backfill(
    repo: &Path,
    changes: &ChangeSet,
    files: &[PathBuf],
    mode: &MutationMode,
) -> Result<()> {
    if !mode.commits() || !changes.changed() || files.is_empty() {
        return Ok(());
    }
    let entries: Vec<&Entry> = changes
        .entries
        .iter()
        .filter(|entry| entry.kind == EntryKind::Backfill)
        .collect();
    let message = match entries.as_slice() {
        [only] => ChangeSet::commit_message(only),
        many => format!("pkgs: backfill registry history ({} versions)", many.len()),
    };
    let relative: Vec<String> = files
        .iter()
        .map(|file| {
            file.strip_prefix(repo)
                .unwrap_or(file)
                .to_string_lossy()
                .to_string()
        })
        .collect();
    let paths: Vec<&str> = relative.iter().map(String::as_str).collect();
    crate::support::nix::fmt(repo)?;
    crate::support::git::commit(
        repo,
        crate::support::git::Stage::Paths(&paths),
        &message,
        mode.committer().as_ref(),
    )?;
    Ok(())
}

pub fn run_versions(command: VersionsCommand) -> Result<CommandStatus> {
    let repo = crate::support::git::repo_root()?;
    let recipe = command.comment_recipe();
    match command {
        VersionsCommand::Add {
            spec,
            per_major,
            per_minor,
            since,
            project,
            variants,
            note,
            force,
            dry_run,
            mode,
        } => {
            let branch = format!(
                "auto/backfill-{}",
                spec.split_once('@').map(|(name, _)| name).unwrap_or(&spec)
            );
            let backfill = history::add(
                &repo,
                history::AddCommand {
                    spec,
                    per_major,
                    per_minor,
                    since,
                    project,
                    dry_run,
                    options: history::AddOptions {
                        variants: (!variants.is_empty()).then_some(variants),
                        note,
                        force,
                        skip_unsupported: false,
                    },
                },
            )?;
            let changes = backfill_changes(backfill.outcomes, mode.commits() && !dry_run);
            commit_backfill(&repo, &changes, &backfill.files, &mode)?;
            conclude(
                &repo,
                &changes,
                &mode,
                PrShape {
                    branch: Some(branch),
                    title: Some("pkgs: backfill registry history".into()),
                    recipe: None,
                    ownership: targets::Ownership::default(),
                },
                None,
            )
        }
        VersionsCommand::Import {
            lockfile,
            dry_run,
            mode,
        } => {
            let backfill = history::from_lockfile(&repo, &lockfile, dry_run)?;
            let changes = backfill_changes(backfill.outcomes, mode.commits() && !dry_run);
            commit_backfill(&repo, &changes, &backfill.files, &mode)?;
            conclude(
                &repo,
                &changes,
                &mode,
                PrShape {
                    branch: Some("auto/backfill-import".into()),
                    title: Some("pkgs: backfill registry history".into()),
                    recipe: None,
                    ownership: targets::Ownership::default(),
                },
                None,
            )
        }
        VersionsCommand::Bump {
            specs,
            all_versions,
            changed_from,
            changed,
            mode,
        } => {
            if changed {
                return request_error("--changed is comment only; use --changed-from REF");
            }
            let changes = bump_rels(
                &repo,
                BumpRequest {
                    specs,
                    all_versions,
                    changed_from: changed_from.as_deref(),
                    commit: mode.commits(),
                    committer: mode.committer(),
                },
            )?;
            conclude(
                &repo,
                &changes,
                &mode,
                PrShape {
                    branch: Some("auto/bump-rel".into()),
                    title: Some("pkgs: bump publication releases".into()),
                    recipe,
                    ownership: targets::Ownership::default(),
                },
                None,
            )
        }
    }
}

pub(crate) struct BumpRequest<'a> {
    pub specs: Vec<String>,
    pub all_versions: bool,
    pub changed_from: Option<&'a str>,
    pub commit: bool,
    pub committer: Option<crate::support::git::Identity<'static>>,
}

/// Bump publication rels into a ChangeSet; the terminal arm and the comment
/// mutation both run this.
pub(crate) fn bump_rels(repo: &Path, request: BumpRequest<'_>) -> Result<ChangeSet> {
    let specs = match request.changed_from {
        Some(reference) => rels::changed(repo, reference)?,
        None => request.specs,
    };
    if specs.is_empty() {
        return request_error("nothing selected to bump");
    }
    let bumps = rels::bump(repo, &specs, request.all_versions)?;
    let mut changes = ChangeSet {
        committed: request.commit,
        ..ChangeSet::default()
    };
    for bump in &bumps {
        changes.entries.push(Entry {
            kind: EntryKind::Rel,
            subject: format!("{} {}", bump.package, bump.version),
            from: Some(bump.before.to_string()),
            to: Some(bump.after.to_string()),
            detail: Some(format!("kind: {}", bump.kind)),
            changelog: bump.changelog.clone(),
            files: vec!["release-revisions.json".into()],
        });
    }
    if request.commit && changes.changed() {
        crate::support::nix::fmt(repo)?;
        let message = if bumps.len() == 1 {
            format!(
                "pkgs: bump {} {} rel to wasix.{}",
                bumps[0].package, bumps[0].version, bumps[0].after
            )
        } else {
            format!("pkgs: bump {} publication rels", bumps.len())
        };
        crate::support::git::commit(
            repo,
            crate::support::git::Stage::Paths(&["release-revisions.json"]),
            &message,
            request.committer.as_ref(),
        )?;
    }
    Ok(changes)
}
