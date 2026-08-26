//! GitHub state owned by a managed update pull request.

use serde_json::json;

use crate::github::client::Client;
use crate::support::error::Result;
use crate::update::targets::Ownership;

const AUTOMATION_LABELS: &[&str] = &["3.automated", "3.automated: update"];
const REBUILD_LABEL_PREFIX: &str = "10.rebuild-wasix: ";

pub fn rebuild_label(count: usize) -> &'static str {
    match count {
        0 => "10.rebuild-wasix: 0",
        1 => "10.rebuild-wasix: 1",
        2..=10 => "10.rebuild-wasix: 1-10",
        11..=100 => "10.rebuild-wasix: 11-100",
        101..=500 => "10.rebuild-wasix: 101-500",
        _ => "10.rebuild-wasix: 501+",
    }
}

pub fn reconcile_rebuild_label(
    client: &Client,
    repository: &str,
    pull_request: u64,
    count: usize,
) -> Result<()> {
    let issue = format!("repos/{repository}/issues/{pull_request}");
    let current = client.get(&issue)?;
    let labels = current["labels"]
        .as_array()
        .ok_or_else(|| crate::support::error::Error::Failure("pull request has no labels".into()))?
        .iter()
        .filter_map(|label| label["name"].as_str())
        .filter(|label| !label.starts_with(REBUILD_LABEL_PREFIX))
        .chain(std::iter::once(rebuild_label(count)))
        .collect::<Vec<_>>();
    client.put(&format!("{issue}/labels"), &json!({ "labels": labels }))?;
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

#[cfg(test)]
mod tests {
    #[test]
    fn rebuild_buckets_cover_every_boundary() {
        use super::rebuild_label;

        assert_eq!(rebuild_label(0), "10.rebuild-wasix: 0");
        assert_eq!(rebuild_label(1), "10.rebuild-wasix: 1");
        assert_eq!(rebuild_label(2), "10.rebuild-wasix: 1-10");
        assert_eq!(rebuild_label(10), "10.rebuild-wasix: 1-10");
        assert_eq!(rebuild_label(11), "10.rebuild-wasix: 11-100");
        assert_eq!(rebuild_label(100), "10.rebuild-wasix: 11-100");
        assert_eq!(rebuild_label(101), "10.rebuild-wasix: 101-500");
        assert_eq!(rebuild_label(500), "10.rebuild-wasix: 101-500");
        assert_eq!(rebuild_label(501), "10.rebuild-wasix: 501+");
    }
}
