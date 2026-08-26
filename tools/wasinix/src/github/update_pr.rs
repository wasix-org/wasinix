//! GitHub state owned by a managed update pull request.

use serde_json::json;

use crate::github::client::Client;
use crate::support::error::Result;
use crate::update::targets::Ownership;

const AUTOMATION_LABELS: &[&str] = &["3.automated", "3.automated: update"];

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
            &json!({ "assignees": ownership.assignees }),
        )?;
    }
    if !ownership.reviewers.is_empty() {
        client.post(
            &format!("repos/{repository}/pulls/{pull_request}/requested_reviewers"),
            &json!({ "reviewers": ownership.reviewers }),
        )?;
    }
    Ok(())
}
