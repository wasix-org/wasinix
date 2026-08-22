//! Opening a mutation as a pull request: one pipeline (commits already made by
//! the driver, then branch, push, PR upsert) whether the bot or a human drives
//! it. Only the credential and the managed footer differ.

use std::path::Path;

use serde_json::json;

use crate::github::changeset;
use crate::github::client::Client;
use crate::support::error::{Error, Result, request_error};
use crate::support::git::git;
use crate::update::changeset::ChangeSet;

pub struct PrOptions {
    pub repository: String,
    pub branch: String,
    pub title: String,
    /// The base branch the PR targets.
    pub base: String,
    /// Whether the bot owns the branch (managed footer, force-push allowed).
    pub managed: bool,
    /// The command that regenerates this branch, recorded in the PR body so
    /// `/wasinix update` and `/wasinix regenerate` can replay it. None for a
    /// mutation no comment can spell, which then advertises neither.
    pub recipe: Option<String>,
}

/// Push the committed changes to `branch` and open or update its PR. The
/// driver has already committed; this only publishes.
pub fn open_pr(repo: &Path, changes: &ChangeSet, options: &PrOptions) -> Result<u64> {
    if !changes.changed() {
        return request_error("nothing to open a PR for; no pins moved");
    }
    // The driver commits each change; an unstaged tree means it ran without
    // --commit, and the push would omit the work.
    if !git(repo, &["status", "--porcelain"])?.trim().is_empty() {
        return request_error("open_pr needs a committed tree; run the mutation with --commit");
    }
    // Managed branches are the bot's, so replacing them is safe; the lease
    // still refuses to clobber a push that landed since this run last read
    // the remote. A human branch is never force-pushed.
    let head_ref = options.head_ref();
    let lease = format!("--force-with-lease=refs/heads/{}", options.branch);
    let mut push = vec!["push", "origin", &head_ref];
    if options.managed {
        push.insert(1, lease.as_str());
    }
    git(repo, &push)?;

    let client = Client::new(crate::github::client::token().as_deref());
    let recipe = options.recipe.clone().filter(|_| options.managed);
    let mut body = crate::github::markdown::truncate_sections(
        changeset::pr_body(changes, recipe.is_some()).into_string(),
        changeset::PR_BODY_BUDGET,
    );
    // Recorded after the truncation, so a body at the budget drops sections
    // rather than the marker every later comment mutation reads.
    if let Some(recipe) = recipe {
        let head = git(repo, &["rev-parse", "HEAD"])?.trim().to_string();
        let state = crate::update::managed::State::new(recipe, head)?;
        body = crate::update::managed::with_state(&body, &state)?;
    }
    if let Some(number) = existing_pr(&client, options)? {
        client.patch(
            &format!("repos/{}/pulls/{number}", options.repository),
            &json!({ "title": options.title, "body": body }),
        )?;
        return Ok(number);
    }
    let created = client.post(
        &format!("repos/{}/pulls", options.repository),
        &json!({
            "title": options.title,
            "head": options.branch,
            "base": options.base,
            "body": body,
        }),
    )?;
    created["number"]
        .as_u64()
        .ok_or_else(|| Error::Failure("created pull request has no number".into()))
}

fn existing_pr(client: &Client, options: &PrOptions) -> Result<Option<u64>> {
    let owner = options.repository.split('/').next().unwrap_or_default();
    let pulls = client.paginate(&format!(
        "repos/{}/pulls?state=open&head={owner}:{}",
        options.repository, options.branch
    ))?;
    Ok(pulls.first().and_then(|pull| pull["number"].as_u64()))
}

impl PrOptions {
    fn head_ref(&self) -> String {
        format!("HEAD:refs/heads/{}", self.branch)
    }
}

/// The pull request facts a mutation needs, typed from the API document.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pull {
    pub head_sha: String,
    pub head_ref: String,
    pub head_repository: String,
    pub base_sha: String,
    pub body: String,
}

pub fn pull(client: &Client, repository: &str, number: u64) -> Result<Pull> {
    let value = client.get(&format!("repos/{repository}/pulls/{number}"))?;
    let field = |pointer: &str| -> Result<String> {
        value
            .pointer(pointer)
            .and_then(|v| v.as_str())
            .map(str::to_string)
            .ok_or_else(|| Error::Failure(format!("pull request has no {pointer}")))
    };
    Ok(Pull {
        head_sha: field("/head/sha")?.to_lowercase(),
        head_ref: field("/head/ref")?,
        head_repository: field("/head/repo/full_name")?.to_lowercase(),
        base_sha: field("/base/sha")?.to_lowercase(),
        body: value["body"].as_str().unwrap_or_default().to_string(),
    })
}

/// Everything the publish job needs, written by `ci mutate` and re-verified
/// against live GitHub state before anything is pushed.
#[derive(Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Context {
    pub origin: crate::ci::origin::Origin,
    pub command: String,
    pub pull: Pull,
    pub start_sha: String,
    /// A regenerate replaces the branch; anything else only extends it.
    pub force: bool,
    /// Whether the managed-state record is rewritten after the push.
    pub record_state: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recipe: Option<String>,
}

impl crate::support::schema::Document for Context {
    const KIND: &'static str = "mutationContext";
    const SCHEMA: u32 = 1;
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Generated {
    pub start_sha: String,
    pub head_sha: String,
    pub changed: bool,
}

impl crate::support::schema::Document for Generated {
    const KIND: &'static str = "mutationResult";
    const SCHEMA: u32 = 1;
}

fn bot_committer() -> crate::support::git::Identity<'static> {
    crate::support::git::Identity {
        name: crate::github::surfaces::BOT_AUTHOR,
        email: crate::github::surfaces::BOT_EMAIL,
    }
}

/// `/wasinix fmt`: the repo's own formatter over the pull request's tree,
/// committed as one change. The entry counts the files, since a formatting
/// commit is otherwise opaque in the reply.
fn format_tree(worktree: &Path) -> Result<ChangeSet> {
    use crate::update::changeset::{Entry, EntryKind, Unchanged};
    crate::support::nix::fmt(worktree)?;
    let files: Vec<String> = git(worktree, &["diff", "--name-only"])?
        .lines()
        .map(str::to_string)
        .collect();
    let mut changes = ChangeSet::default();
    if files.is_empty() {
        changes.unchanged.push(Unchanged {
            subject: "formatting".into(),
            detail: "the tree is already formatted".into(),
        });
        return Ok(changes);
    }
    let entry = Entry {
        kind: EntryKind::Format,
        subject: "formatting".into(),
        from: None,
        to: None,
        detail: Some(format!("{} files reformatted", files.len())),
        changelog: None,
        files,
    };
    changes.committed = crate::support::git::commit(
        worktree,
        crate::support::git::Stage::All,
        &ChangeSet::commit_message(&entry),
        Some(&bot_committer()),
    )?;
    changes.entries.push(entry);
    Ok(changes)
}

fn mutation_registry<'a>(
    client: &'a Client,
    origin: &crate::ci::origin::Origin,
) -> crate::github::surfaces::Registry<'a> {
    crate::github::surfaces::Registry::new(
        client,
        origin.repository.clone(),
        origin.pull_request,
        crate::github::surfaces::BOT_AUTHOR,
        crate::support::effects::Effects::Apply,
    )
}

/// The answering line every mutation reply opens with, so the reply names
/// the comment it acts on.
fn reply_origin_line(origin: &crate::ci::origin::Origin) -> crate::github::sanitize::Markdown {
    use crate::github::sanitize::Markdown;
    let url = crate::github::surfaces::origin_comment_url(
        &origin.repository,
        origin.pull_request,
        origin.comment_id,
    );
    Markdown::concat([
        Markdown::constant("<sub>"),
        Markdown::html_link("\u{21b3} in reply to this command", &url),
        Markdown::constant("</sub>\n\n"),
    ])
}

fn reply_surface(origin: &crate::ci::origin::Origin) -> crate::github::surfaces::Surface {
    crate::github::surfaces::Surface::Mutation {
        comment_id: origin.comment_id,
    }
}

/// The paused warning: what moved, and what still runs against it.
fn paused_reply(
    state: &crate::update::managed::State,
    pull: &Pull,
    client: &Client,
    origin: &crate::ci::origin::Origin,
) -> crate::github::sanitize::Markdown {
    use crate::github::sanitize::Markdown;
    let mut body = Markdown::concat([
        Markdown::constant(
            "### ⛔ Automated refresh blocked\n\nThe branch moved past the \
            recorded head ",
        ),
        Markdown::code(&state.rewrite_safe_head),
        Markdown::constant(", so a refresh would replace commits the bot did not write.\n"),
    ]);
    let compared = client.get(&format!(
        "repos/{}/compare/{}...{}",
        origin.repository, state.rewrite_safe_head, pull.head_sha
    ));
    if let Ok(compared) = compared {
        for commit in compared["commits"].as_array().into_iter().flatten() {
            let sha: String = commit["sha"]
                .as_str()
                .unwrap_or_default()
                .chars()
                .take(12)
                .collect();
            let title = commit["commit"]["message"]
                .as_str()
                .unwrap_or_default()
                .lines()
                .next()
                .unwrap_or_default()
                .to_string();
            body = Markdown::concat([
                body,
                Markdown::constant("- "),
                Markdown::code(&sha),
                Markdown::constant(" "),
                Markdown::text(&title),
                Markdown::constant("\n"),
            ]);
        }
    }
    body.push(Markdown::constant(
        "\n`/wasinix update <targets>` still runs as spelled, on top of those commits. \
         Automated refreshes stay paused until the branch is the bot's again: \
         `/wasinix regenerate` discards the commits above and rebuilds it from the \
         recorded recipe.\n",
    ))
}

/// What a comment mutation resolves to once the managed record has spoken.
#[derive(Debug, PartialEq)]
pub(crate) struct Resolution {
    pub command: crate::cli::untrusted::MutationCommand,
    pub start_sha: String,
    pub force: bool,
    pub record_state: bool,
    pub recipe: Option<String>,
}

#[derive(Debug, PartialEq)]
pub(crate) enum Resolved {
    Run(Resolution),
    /// "Pushing pauses refreshes": the branch moved past the recorded head.
    Paused(crate::update::managed::State),
}

/// The managed-state gates: a regenerate or a bare update replays a recorded
/// recipe (and only a managed PR has one); everything else runs as spelled
/// from the current head.
pub(crate) fn resolve(
    mutation: crate::cli::untrusted::MutationCommand,
    state: Option<crate::update::managed::State>,
    pull: &Pull,
) -> Result<Resolved> {
    use crate::cli::untrusted::MutationCommand;
    let bare_update = matches!(
        &mutation,
        MutationCommand::Update { targets, all } if targets.is_empty() && !all
    );
    Ok(Resolved::Run(match mutation {
        MutationCommand::Regenerate => {
            let state = crate::update::managed::require_state(state, "regenerate")?;
            let replay = crate::update::managed::parse_recipe(&state.recipe)?;
            Resolution {
                command: replay,
                start_sha: pull.base_sha.clone(),
                force: true,
                record_state: true,
                recipe: Some(state.recipe),
            }
        }
        MutationCommand::Update { .. } if bare_update => {
            let state = crate::update::managed::require_state(state, "a bare update")?;
            if crate::update::managed::paused(&state, &pull.head_sha) {
                return Ok(Resolved::Paused(state));
            }
            let replay = crate::update::managed::parse_recipe(&state.recipe)?;
            if !matches!(replay, MutationCommand::Update { .. }) {
                return request_error("this managed pull request is not an update");
            }
            Resolution {
                command: replay,
                start_sha: pull.head_sha.clone(),
                force: false,
                record_state: true,
                recipe: Some(state.recipe),
            }
        }
        other => Resolution {
            command: other,
            start_sha: pull.head_sha.clone(),
            force: false,
            record_state: false,
            recipe: None,
        },
    }))
}

/// The mutate job: re-verify the authorized comment, resolve the recipe,
/// run the mutation in a worktree of the PR head with the bot committer, and
/// leave a bundle plus the context the publish job re-verifies. Runs with no
/// push credential; the PR tree's own update scripts execute here.
pub fn mutate(repo: &Path, origin_doc: &Path, out_dir: &Path) -> Result<()> {
    // The bundle is written by a `git -C <worktree>` invocation, which
    // resolves a relative out-dir inside the worktree instead of the
    // caller's directory.
    let out_dir = &crate::support::fs::absolute(out_dir)?;
    let command: crate::ci::origin::Command = crate::support::schema::read(origin_doc)?;
    let api = crate::github::client::Client::new(None);
    crate::ci::origin::verify(
        &command.origin,
        &command.command,
        &api,
        &crate::cli::untrusted::ClapClassifier,
    )?;
    let mutation = match crate::cli::untrusted::parse(&command.command)? {
        crate::cli::untrusted::UntrustedCommand::Mutation(mutation) => mutation,
        _ => return request_error("not a mutation command"),
    };
    let current = crate::github::surfaces::detected_repository(repo).unwrap_or_default();
    if !command.origin.repository.eq_ignore_ascii_case(&current) {
        return request_error(format!("mutation comments are accepted only on {current}"));
    }
    let client = Client::new(crate::github::client::token().as_deref());
    let pull = pull(
        &client,
        &command.origin.repository,
        command.origin.pull_request,
    )?;
    if !pull
        .head_repository
        .eq_ignore_ascii_case(&command.origin.repository)
    {
        return request_error("mutation comments cannot write to a fork pull request");
    }
    let state = crate::update::managed::decode(&pull.body)?;

    let resolution = resolve(mutation, state, &pull)?;
    let Resolution {
        command: resolved,
        start_sha,
        force,
        record_state,
        recipe,
    } = match resolution {
        Resolved::Run(resolution) => resolution,
        Resolved::Paused(state) => {
            let mut registry = mutation_registry(&client, &command.origin);
            registry.upsert(
                &reply_surface(&command.origin),
                &[],
                reply_origin_line(&command.origin).push(paused_reply(
                    &state,
                    &pull,
                    &client,
                    &command.origin,
                )),
            )?;
            return request_error(
                "automated refreshes are paused: the branch moved past the recorded head",
            );
        }
    };

    use crate::cli::untrusted::MutationCommand;
    let worktree = crate::ci::workspace::Worktree::add(repo, &start_sha)?;
    let changes = match resolved {
        MutationCommand::Update { targets, all } => crate::update::drive::drive(
            worktree.path(),
            crate::update::drive::Options {
                hooks_only: false,
                all,
                targets,
                commit: true,
                committer: Some(bot_committer()),
            },
        )?,
        MutationCommand::Bump {
            specs,
            all_versions,
            changed,
        } => crate::cli::update::bump_rels(
            worktree.path(),
            crate::cli::update::BumpRequest {
                specs,
                all_versions,
                changed_from: changed.then_some(pull.base_sha.as_str()),
                commit: true,
                committer: Some(bot_committer()),
            },
        )?,
        MutationCommand::Format => format_tree(worktree.path())?,
        MutationCommand::Regenerate => unreachable!("resolved to its recipe above"),
    };
    if !git(worktree.path(), &["status", "--porcelain"])?
        .trim()
        .is_empty()
    {
        return request_error("the mutation left uncommitted changes");
    }
    let head = git(worktree.path(), &["rev-parse", "HEAD"])?;
    let changed = !head.eq_ignore_ascii_case(&start_sha);

    crate::support::fs::create_dir_all(out_dir)?;
    if changed {
        git(worktree.path(), &["branch", "-f", "mutation-result", &head])?;
        crate::support::git::git_logged(
            worktree.path(),
            &[
                "bundle",
                "create",
                &out_dir.join("commits.bundle").to_string_lossy(),
                "mutation-result",
            ],
        )?;
    }
    crate::support::schema::write(
        &out_dir.join("context.json"),
        &Context {
            origin: command.origin,
            command: command.command,
            pull,
            start_sha: start_sha.clone(),
            force,
            record_state,
            recipe,
        },
    )?;
    crate::support::schema::write(&out_dir.join("changeset.json"), &changes)?;
    crate::support::schema::write(
        &out_dir.join("result.json"),
        &Generated {
            start_sha,
            head_sha: head,
            changed,
        },
    )?;
    if !changes.failures.is_empty() {
        return Err(Error::Failure(format!(
            "{} mutation step(s) failed; see the reply",
            changes.failures.len()
        )));
    }
    Ok(())
}

/// The publish job, the only one with a write credential: re-verify the
/// origin against live state, verify the bundle is exactly what mutate
/// declared, push (with lease when replacing), reply, and record the state.
pub fn mutate_publish(repo: &Path, out_dir: &Path) -> Result<()> {
    // The bundle is read back by a `git -C <scratch>` invocation, the same
    // way `mutate` writes it.
    let out_dir = &crate::support::fs::absolute(out_dir)?;
    let context: Context = crate::support::schema::read(&out_dir.join("context.json"))?;
    let generated: Generated = crate::support::schema::read(&out_dir.join("result.json"))?;
    let changes: ChangeSet = crate::support::schema::read(&out_dir.join("changeset.json"))?;
    if generated.start_sha != context.start_sha {
        return request_error("the mutation result starts from the wrong commit");
    }
    let current = crate::github::surfaces::detected_repository(repo).unwrap_or_default();
    if !context.origin.repository.eq_ignore_ascii_case(&current) {
        return request_error(format!("mutation publishes are accepted only on {current}"));
    }
    let token = crate::github::client::token().ok_or_else(|| {
        Error::Request("publishing a mutation needs GITHUB_TOKEN".into())
    })?;
    let api = crate::github::client::Client::new(Some(&token));
    crate::ci::origin::verify(
        &context.origin,
        &context.command,
        &api,
        &crate::cli::untrusted::ClapClassifier,
    )?;

    let mut new_head = context.pull.head_sha.clone();
    if generated.changed || context.force {
        let scratch = crate::support::fs::Scratch::create("wasinix-mutation-push")?;
        let work = scratch.path();
        // The token rides in the remote URL of a scratch repo that dies with
        // this run; none of these commands echo their argv.
        crate::support::git::git_global(&["init", &work.to_string_lossy()])?;
        git(
            work,
            &[
                "remote",
                "add",
                "origin",
                &format!(
                    "https://x-access-token:{token}@github.com/{}.git",
                    context.origin.repository
                ),
            ],
        )?;
        git(
            work,
            &["fetch", "--no-tags", "origin", &context.pull.head_sha],
        )?;
        let result = if generated.changed {
            git(
                work,
                &[
                    "fetch",
                    &out_dir.join("commits.bundle").to_string_lossy(),
                    "mutation-result",
                ],
            )?;
            git(work, &["rev-parse", "FETCH_HEAD"])?
        } else {
            context.start_sha.clone()
        };
        if !result.eq_ignore_ascii_case(&generated.head_sha) {
            return request_error("the mutation bundle does not match its declared head");
        }
        if context.force {
            git(
                work,
                &[
                    "push",
                    &format!(
                        "--force-with-lease=refs/heads/{}:{}",
                        context.pull.head_ref, context.pull.head_sha
                    ),
                    "origin",
                    &format!("{result}:refs/heads/{}", context.pull.head_ref),
                ],
            )?;
        } else {
            if !crate::support::git::is_ancestor(work, &context.pull.head_sha, &result)? {
                return request_error("the mutation result does not extend the pull request head");
            }
            git(
                work,
                &[
                    "push",
                    "origin",
                    &format!("{result}:refs/heads/{}", context.pull.head_ref),
                ],
            )?;
        }
        new_head = result;
    } else if !generated
        .head_sha
        .eq_ignore_ascii_case(&context.pull.head_sha)
    {
        return request_error("an unchanged mutation result does not match the pull request head");
    }

    let heading = if context.force {
        "### ✅ Wasinix branch regenerated"
    } else if generated.changed {
        "### ✅ Wasinix mutation applied"
    } else {
        "### ℹ️ Wasinix mutation made no changes"
    };
    let mut body = changeset::reply(&changes, heading, &new_head);
    // Pushes from the default token do not trigger CI on the new head; say
    // so instead of leaving a PR that looks unchecked.
    if crate::support::env::update_pr_token_present()? == Some(false) {
        body = body.push(crate::github::sanitize::Markdown::constant(
            "\n> [!NOTE]\n> Pushed with the default token, so CI will not run on the \
             new head until re-triggered; configure the UPDATE_PR_TOKEN secret to cascade.\n",
        ));
    }
    let client = Client::new(Some(&token));
    let mut registry = mutation_registry(&client, &context.origin);
    registry.upsert(
        &reply_surface(&context.origin),
        &[],
        reply_origin_line(&context.origin).push(body),
    )?;

    if context.record_state {
        let recipe = context
            .recipe
            .clone()
            .ok_or_else(|| Error::Failure("a state-recording mutation carries no recipe".into()))?;
        let state = crate::update::managed::State::new(recipe, new_head)?;
        // The body may have moved since mutate ran; record into the fresh one.
        let fresh = pull(
            &client,
            &context.origin.repository,
            context.origin.pull_request,
        )?;
        let rendered = crate::update::managed::with_state(&fresh.body, &state)?;
        client.patch(
            &format!(
                "repos/{}/pulls/{}",
                context.origin.repository, context.origin.pull_request
            ),
            &json!({ "body": rendered }),
        )?;
    }
    if !changes.failures.is_empty() {
        return Err(Error::Failure(format!(
            "{} mutation step(s) failed; see the reply",
            changes.failures.len()
        )));
    }
    Ok(())
}
