use std::time::Duration;

use serde_json::Value;

use crate::github::client::{Api, Client};
use crate::support::error::{Error, Result};
use crate::support::process::CommandStatus;
use crate::support::{time, ui};

pub(crate) const STALE_AFTER_SECONDS: u64 = 3 * crate::github::publish::PROGRESS_INTERVAL_SECONDS;

#[derive(clap::Subcommand)]
pub enum PullRequestCommand {
    /// Follow the current Build run until its Wasinix CI check is final or stale
    Watch {
        pull_request: u64,
        /// GitHub repository; inferred from the environment or checkout when absent
        #[arg(long)]
        repository: Option<String>,
        /// Mark a non-terminal progress check stale after this many seconds
        #[arg(long, default_value_t = STALE_AFTER_SECONDS)]
        stale_after: u64,
    },
}

fn string(value: &Value, path: &[&str]) -> Result<String> {
    path.iter()
        .try_fold(value, |value, key| value.get(*key))
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| Error::Failure(format!("GitHub response has no {}", path.join("."))))
}

fn current_run(api: &dyn Api, repository: &str, sha: &str) -> Result<Option<Value>> {
    let response = api.get(&format!(
        "repos/{repository}/actions/workflows/build.yml/runs?head_sha={sha}&event=pull_request"
    ))?;
    Ok(response["workflow_runs"]
        .as_array()
        .and_then(|runs| runs.iter().max_by_key(|run| run["created_at"].as_str()))
        .cloned())
}

fn matching_check(
    api: &dyn Api,
    repository: &str,
    sha: &str,
    run_url: &str,
) -> Result<Option<Value>> {
    let response = api.get(&format!(
        "repos/{repository}/commits/{sha}/check-runs?check_name=Wasinix%20CI"
    ))?;
    Ok(response["check_runs"].as_array().and_then(|checks| {
        checks
            .iter()
            .filter(|check| {
                check["external_id"].as_str() == Some(run_url)
                    || check["details_url"].as_str() == Some(run_url)
            })
            .max_by_key(|check| check["id"].as_u64())
            .cloned()
    }))
}

pub fn run(repo: &std::path::Path, command: PullRequestCommand) -> Result<CommandStatus> {
    let PullRequestCommand::Watch {
        pull_request,
        repository,
        stale_after,
    } = command;
    if stale_after == 0 {
        return Err(Error::Request("--stale-after must be positive".into()));
    }
    let repository = crate::github::surfaces::resolve_repository(repository.as_deref(), repo)?;
    let client = Client::new(None);
    let pull = client.get(&format!("repos/{repository}/pulls/{pull_request}"))?;
    if string(&pull, &["head", "repo", "full_name"])?.to_lowercase() != repository {
        return Err(Error::Request(
            "watch needs a same-repository pull request".into(),
        ));
    }
    let sha = string(&pull, &["head", "sha"])?;
    let waiting_since = std::time::Instant::now();
    loop {
        let Some(run) = current_run(&client, &repository, &sha)? else {
            if waiting_since.elapsed().as_secs() > stale_after {
                ui::result("Build did not start before the observation deadline");
                return Ok(CommandStatus::from_code(3));
            }
            ui::fact("pull request", "waiting for Build to start");
            std::thread::sleep(Duration::from_secs(60));
            continue;
        };
        let run_url = string(&run, &["html_url"])?;
        let status = string(&run, &["status"])?;
        let check = matching_check(&client, &repository, &sha, &run_url)?;
        if let Some(check) = &check {
            if check["status"].as_str() == Some("completed") {
                let conclusion = string(check, &["conclusion"])?;
                ui::result(format!("{run_url}: {conclusion}"));
                return Ok(if conclusion == "success" {
                    CommandStatus::SUCCESS
                } else {
                    CommandStatus::FAILURE
                });
            }
        }
        if status == "completed" {
            ui::result(format!("{run_url}: incomplete"));
            return Ok(CommandStatus::from_code(2));
        }
        let updated = check
            .as_ref()
            .map(|check| &check["updated_at"])
            .unwrap_or(&run["updated_at"]);
        let updated = string(updated, &[])?;
        let updated = time::parse_utc(&updated)
            .ok_or_else(|| Error::Failure(format!("invalid GitHub timestamp {updated:?}")))?;
        if time::unix_secs().saturating_sub(updated) > stale_after {
            ui::result(format!("{run_url}: stalled since {updated}"));
            return Ok(CommandStatus::from_code(3));
        }
        ui::fact("pull request", format!("{run_url}: {status}"));
        std::thread::sleep(Duration::from_secs(60));
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{Value, json};

    use super::{Api, Result, current_run, matching_check};

    struct FakeApi(Vec<(&'static str, Value)>);

    impl Api for FakeApi {
        fn get(&self, path: &str) -> Result<Value> {
            Ok(self
                .0
                .iter()
                .find(|(expected, _)| *expected == path)
                .unwrap_or_else(|| panic!("unexpected GitHub path: {path}"))
                .1
                .clone())
        }
    }

    #[test]
    fn current_run_uses_the_newest_build_for_the_pull_request_head() {
        let api = FakeApi(vec![(
            "repos/wasix-org/wasinix/actions/workflows/build.yml/runs?head_sha=abc&event=pull_request",
            json!({ "workflow_runs": [
                { "created_at": "2026-08-26T10:00:00Z", "html_url": "old" },
                { "created_at": "2026-08-26T11:00:00Z", "html_url": "new" }
            ] }),
        )]);

        assert_eq!(
            current_run(&api, "wasix-org/wasinix", "abc")
                .unwrap()
                .unwrap()["html_url"],
            "new"
        );
    }

    #[test]
    fn matching_check_requires_the_exact_build_run_url() {
        let api = FakeApi(vec![(
            "repos/wasix-org/wasinix/commits/abc/check-runs?check_name=Wasinix%20CI",
            json!({ "check_runs": [
                { "id": 9, "external_id": "https://github.com/wasix-org/wasinix/actions/runs/other" },
                { "id": 2, "details_url": "https://github.com/wasix-org/wasinix/actions/runs/current" },
                { "id": 3, "external_id": "https://github.com/wasix-org/wasinix/actions/runs/current" }
            ] }),
        )]);

        assert_eq!(
            matching_check(
                &api,
                "wasix-org/wasinix",
                "abc",
                "https://github.com/wasix-org/wasinix/actions/runs/current",
            )
            .unwrap()
            .unwrap()["id"],
            3
        );
    }
}
