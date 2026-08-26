//! GitHub state owned by a managed update pull request.

use serde_json::json;

use crate::github::client::Client;
use crate::support::error::Result;
use crate::update::targets::Ownership;

const AUTOMATION_LABELS: &[&str] = &["3.automated", "3.automated: update"];

pub fn enable_auto_merge(client: &Client, pull: &crate::github::mutation::Pull) -> Result<()> {
    if pull.auto_merge_enabled {
        return Ok(());
    }
    client.graphql(&json!({
        "query": "mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id, mergeMethod: SQUASH}) { pullRequest { number } } }",
        "variables": { "id": pull.node_id },
    }))?;
    Ok(())
}

pub fn disable_auto_merge(client: &Client, pull: &crate::github::mutation::Pull) -> Result<()> {
    if !pull.auto_merge_enabled {
        return Ok(());
    }
    client.graphql(&json!({
        "query": "mutation($id: ID!) { disablePullRequestAutoMerge(input: {pullRequestId: $id}) { pullRequest { number } } }",
        "variables": { "id": pull.node_id },
    }))?;
    Ok(())
}

/// Apply facts that come from the update declaration, never from a branch
/// name or title. GitHub additions are idempotent, so replaying an update
/// reasserts the contract without touching unrelated labels or reviewers.
pub fn reconcile(
    client: &Client,
    repository: &str,
    pull_request: u64,
    ownership: &Ownership,
) -> Result<()> {
    let issue = format!("repos/{repository}/issues/{pull_request}");
    client.post(
        &format!("{issue}/labels"),
        &json!({ "labels": AUTOMATION_LABELS }),
    )?;
    if !ownership.assignees.is_empty() {
        client.post(
            &format!("{issue}/assignees"),
            &json!({ "assignees": ownership.assignees.iter().map(|maintainer| &maintainer.github).collect::<Vec<_>>() }),
        )?;
    }
    if !ownership.reviewers.is_empty() {
        client.post(
            &format!("repos/{repository}/pulls/{pull_request}/requested_reviewers"),
            &json!({ "reviewers": ownership.reviewers.iter().map(|maintainer| &maintainer.github).collect::<Vec<_>>() }),
        )?;
    }
    Ok(())
}

pub fn defer_human_edits(
    client: &Client,
    repository: &str,
    pull_request: u64,
    state: &crate::update::managed::State,
    head_sha: &str,
) -> Result<()> {
    let issue = format!("repos/{repository}/issues/{pull_request}");
    client.post(
        &format!("{issue}/labels"),
        &json!({ "labels": ["3.automated: deferred-human-edits"] }),
    )?;
    let mut registry = crate::github::surfaces::Registry::new(
        client,
        repository,
        pull_request,
        crate::github::surfaces::BOT_AUTHOR,
        crate::support::effects::Effects::Apply,
    );
    let body = crate::github::sanitize::Markdown::concat([
        crate::github::sanitize::Markdown::constant("### Automated update deferred\n\n"),
        crate::github::sanitize::Markdown::constant(
            "A newer update is ready, but this branch moved past the bot-recorded head ",
        ),
        crate::github::sanitize::Markdown::code(&state.rewrite_safe_head),
        crate::github::sanitize::Markdown::constant(" to "),
        crate::github::sanitize::Markdown::code(head_sha),
        crate::github::sanitize::Markdown::constant(".\n"),
        crate::github::changeset::managed_footer(),
    ]);
    registry.upsert(
        &crate::github::surfaces::Surface::UpdateDeferred,
        &[("state", "deferred-human-edits".into())],
        body,
    )?;
    Ok(())
}
