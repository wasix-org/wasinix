//! The GitHub Actions file boundary. Step outputs are scalar records, so a
//! value containing a line break is invalid rather than a second record.

use std::io::Write;
use std::path::Path;
use std::sync::LazyLock;

use crate::support::error::{Error, Result};

static REPOSITORY: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$").unwrap()
});

#[cfg(test)]
pub const ARTIFACT_CI_RUN: &str = "ci-run";
pub const OUTPUT_BIN: &str = "bin";
pub const OUTPUT_BASE_REF: &str = "baseRef";
pub const OUTPUT_COMMENT_ID: &str = "commentId";
pub const OUTPUT_HEAD_SHA: &str = "headSha";
pub const OUTPUT_KIND: &str = "kind";
pub const OUTPUT_PULL_REQUEST: &str = "pullRequest";
pub const OUTPUT_PROCEED: &str = "proceed";
pub const OUTPUT_REPORTED: &str = "reported";
pub const OUTPUT_RUN_DIR: &str = "runDir";
pub const OUTPUT_RUN_ID: &str = "runId";
pub const OUTPUT_TAG: &str = "tag";

pub fn is_repository(value: &str) -> bool {
    REPOSITORY.is_match(value)
}

pub fn open_pull_request(
    api: &dyn crate::github::client::Api,
    repository: &str,
    head_sha: &crate::support::atoms::Rev,
    head_repository: &str,
) -> Result<Option<u64>> {
    if !is_repository(repository) || !is_repository(head_repository) {
        return Err(Error::Request(
            "repository and head repository must be OWNER/REPO".into(),
        ));
    }
    let pulls = crate::github::client::paginate(
        api,
        &format!("repos/{repository}/commits/{}/pulls", head_sha.full()),
    )?;
    let matches: Vec<&serde_json::Value> = pulls
        .iter()
        .filter(|pull| {
            pull["state"] == "open"
                && pull["head"]["sha"].as_str() == Some(head_sha.full())
                && pull["head"]["repo"]["full_name"].as_str() == Some(head_repository)
        })
        .collect();
    match matches.as_slice() {
        [] => Ok(None),
        [pull] => pull["number"]
            .as_u64()
            .filter(|number| *number > 0)
            .map(Some)
            .ok_or_else(|| {
                Error::Failure("GitHub returned a pull request without a positive number".into())
            }),
        _ => Err(Error::Failure(format!(
            "GitHub returned {} open pull requests for {head_repository}@{head_sha}",
            matches.len()
        ))),
    }
}

pub struct PreviewContext {
    pub proceed: bool,
    pub pull_request: Option<u64>,
    pub head_sha: Option<crate::support::atoms::Rev>,
    pub base_ref: Option<String>,
    pub tag: Option<String>,
    pub note: Option<String>,
}

impl PreviewContext {
    pub fn outputs(&self) -> Vec<(&'static str, String)> {
        vec![
            (OUTPUT_PROCEED, self.proceed.to_string()),
            (
                OUTPUT_PULL_REQUEST,
                self.pull_request
                    .map(|number| number.to_string())
                    .unwrap_or_default(),
            ),
            (
                OUTPUT_HEAD_SHA,
                self.head_sha
                    .as_ref()
                    .map(|sha| sha.full().to_string())
                    .unwrap_or_default(),
            ),
            (OUTPUT_BASE_REF, self.base_ref.clone().unwrap_or_default()),
            (OUTPUT_TAG, self.tag.clone().unwrap_or_default()),
        ]
    }
}

pub fn preview_context(
    api: &dyn crate::github::client::Api,
    repository: &str,
    event: &serde_json::Value,
) -> Result<PreviewContext> {
    if !is_repository(repository) {
        return Err(Error::Request("repository must be OWNER/REPO".into()));
    }
    let (pull_request, head_sha) = if event["workflow_run"].is_object() {
        let run = &event["workflow_run"];
        if run["event"] != "pull_request" || run["conclusion"] != "success" {
            return Ok(no_preview(None, None, None));
        }
        let head_sha = crate::support::atoms::Rev::parse(
            run["head_sha"]
                .as_str()
                .ok_or_else(|| Error::Failure("workflow run has no head SHA".into()))?,
        )?;
        let head_repository = run["head_repository"]["full_name"]
            .as_str()
            .ok_or_else(|| Error::Failure("workflow run has no head repository".into()))?;
        if head_repository != repository {
            return Ok(no_preview(None, Some(head_sha), None));
        }
        let pull_request = open_pull_request(api, repository, &head_sha, head_repository)?;
        (pull_request, head_sha)
    } else {
        let pull = &event["pull_request"];
        let number = pull["number"]
            .as_u64()
            .filter(|number| *number > 0)
            .ok_or_else(|| Error::Failure("pull request event has no positive number".into()))?;
        let head_sha = crate::support::atoms::Rev::parse(
            pull["head"]["sha"]
                .as_str()
                .ok_or_else(|| Error::Failure("pull request event has no head SHA".into()))?,
        )?;
        let head_repository = pull["head"]["repo"]["full_name"]
            .as_str()
            .ok_or_else(|| Error::Failure("pull request event has no head repository".into()))?;
        if event["action"] != "labeled"
            || event["label"]["name"] != "preview"
            || head_repository != repository
        {
            return Ok(no_preview(Some(number), Some(head_sha), None));
        }
        let runs = api.get(&format!(
            "repos/{repository}/actions/workflows/build.yml/runs?head_sha={}&per_page=1",
            head_sha.full()
        ))?;
        let runs = runs["workflow_runs"]
            .as_array()
            .ok_or_else(|| Error::Failure("GitHub workflow runs response is not a list".into()))?;
        let green = runs.first().and_then(|run| run["conclusion"].as_str()) == Some("success");
        if !green {
            return Ok(no_preview(
                Some(number),
                Some(head_sha.clone()),
                Some(format!(
                    "Build for {} is not green yet; its workflow run will retry the preview",
                    head_sha.full()
                )),
            ));
        }
        (Some(number), head_sha)
    };

    let Some(pull_request) = pull_request else {
        return Ok(no_preview(None, Some(head_sha), None));
    };
    let pull = api.get(&format!("repos/{repository}/pulls/{pull_request}"))?;
    let live_number = pull["number"]
        .as_u64()
        .filter(|number| *number > 0)
        .ok_or_else(|| Error::Failure("GitHub pull request has no positive number".into()))?;
    let state = pull["state"]
        .as_str()
        .ok_or_else(|| Error::Failure("GitHub pull request has no state".into()))?;
    let live_sha = pull["head"]["sha"]
        .as_str()
        .ok_or_else(|| Error::Failure("GitHub pull request has no head SHA".into()))?;
    let live_repository = pull["head"]["repo"]["full_name"]
        .as_str()
        .ok_or_else(|| Error::Failure("GitHub pull request has no head repository".into()))?;
    let labels = pull["labels"]
        .as_array()
        .ok_or_else(|| Error::Failure("GitHub pull request has no label list".into()))?;
    let labeled = labels
        .iter()
        .any(|label| label["name"].as_str() == Some("preview"));
    if live_number != pull_request
        || state != "open"
        || live_sha != head_sha.full()
        || live_repository != repository
        || !labeled
    {
        return Ok(no_preview(Some(pull_request), Some(head_sha), None));
    }
    let base_ref = pull["base"]["ref"]
        .as_str()
        .filter(|base| !base.is_empty())
        .ok_or_else(|| Error::Failure("GitHub pull request has no base ref".into()))?
        .to_string();
    // The g makes an all-digit SHA prefix with a leading zero valid semver.
    let tag = format!("pr{pull_request}.g{}", &head_sha.full()[..7]);
    Ok(PreviewContext {
        proceed: true,
        pull_request: Some(pull_request),
        head_sha: Some(head_sha),
        base_ref: Some(base_ref),
        tag: Some(tag),
        note: None,
    })
}

fn no_preview(
    pull_request: Option<u64>,
    head_sha: Option<crate::support::atoms::Rev>,
    note: Option<String>,
) -> PreviewContext {
    PreviewContext {
        proceed: false,
        pull_request,
        head_sha,
        base_ref: None,
        tag: None,
        note,
    }
}

pub fn append(path: &Path, outputs: &[(&str, String)]) -> Result<()> {
    let text = render(outputs)?;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|source| crate::support::error::io(path, source))?;
    file.write_all(text.as_bytes())
        .map_err(|source| crate::support::error::io(path, source))
}

fn render(outputs: &[(&str, String)]) -> Result<String> {
    let mut text = String::new();
    for (name, value) in outputs {
        let valid_name = !name.is_empty()
            && name.chars().enumerate().all(|(index, character)| {
                character == '_'
                    || character.is_ascii_alphanumeric()
                        && (index > 0 || character.is_ascii_alphabetic())
            });
        if !valid_name {
            return Err(Error::Failure(format!(
                "invalid GitHub Actions output name {name:?}"
            )));
        }
        if value.contains(['\r', '\n']) {
            return Err(Error::Failure(format!(
                "GitHub Actions output {name} is not a scalar"
            )));
        }
        text.push_str(name);
        text.push('=');
        text.push_str(value);
        text.push('\n');
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn outputs_are_one_record_each() {
        assert_eq!(
            render(&[(OUTPUT_KIND, "build".into()), (OUTPUT_RUN_ID, "42".into())]).unwrap(),
            "kind=build\nrunId=42\n"
        );
    }

    #[test]
    fn names_and_values_cannot_inject_records() {
        assert!(render(&[("bad-name", "value".into())]).is_err());
        assert!(render(&[(OUTPUT_KIND, "build\nadmin=true".into())]).is_err());
    }

    struct Fake(serde_json::Value);

    impl crate::github::client::Api for Fake {
        fn get(&self, path: &str) -> Result<serde_json::Value> {
            assert_eq!(
                path,
                format!(
                    "repos/base/repo/commits/{}/pulls?per_page=100&page=1",
                    "a".repeat(40)
                )
            );
            Ok(self.0.clone())
        }
    }

    #[test]
    fn pull_requests_match_state_sha_and_head_repository_exactly() {
        let sha = crate::support::atoms::Rev::parse(&"a".repeat(40)).unwrap();
        let pull = |number, state: &str, sha: &str, repository: &str| {
            serde_json::json!({
                "number": number,
                "state": state,
                "head": {"sha": sha, "repo": {"full_name": repository}},
            })
        };
        let api = Fake(serde_json::json!([
            pull(1, "closed", sha.full(), "fork/repo"),
            pull(2, "open", sha.full(), "other/repo"),
            pull(3, "open", sha.full(), "fork/repo"),
        ]));
        assert_eq!(
            open_pull_request(&api, "base/repo", &sha, "fork/repo").unwrap(),
            Some(3)
        );
        let ambiguous = Fake(serde_json::json!([
            pull(3, "open", sha.full(), "fork/repo"),
            pull(4, "open", sha.full(), "fork/repo"),
        ]));
        assert!(open_pull_request(&ambiguous, "base/repo", &sha, "fork/repo").is_err());
    }

    struct Routes(std::collections::BTreeMap<String, serde_json::Value>);

    impl crate::github::client::Api for Routes {
        fn get(&self, path: &str) -> Result<serde_json::Value> {
            self.0
                .get(path)
                .cloned()
                .ok_or_else(|| Error::Failure(format!("unexpected GitHub path {path}")))
        }
    }

    #[test]
    fn a_labeled_preview_requires_a_green_build_and_live_matching_pr() {
        let sha = "b".repeat(40);
        let event = serde_json::json!({
            "action": "labeled",
            "label": {"name": "preview"},
            "pull_request": {
                "number": 7,
                "head": {"sha": sha, "repo": {"full_name": "base/repo"}},
            },
        });
        let pull = serde_json::json!({
            "number": 7,
            "state": "open",
            "head": {"sha": sha, "repo": {"full_name": "base/repo"}},
            "base": {"ref": "main"},
            "labels": [{"name": "preview"}],
        });
        let build_path =
            format!("repos/base/repo/actions/workflows/build.yml/runs?head_sha={sha}&per_page=1");
        let api = Routes(std::collections::BTreeMap::from([
            (
                build_path.clone(),
                serde_json::json!({"workflow_runs": [{"conclusion": "success"}]}),
            ),
            ("repos/base/repo/pulls/7".into(), pull),
        ]));
        let context = preview_context(&api, "base/repo", &event).unwrap();
        assert!(context.proceed);
        assert_eq!(context.base_ref.as_deref(), Some("main"));
        assert_eq!(context.tag.as_deref(), Some("pr7.gbbbbbbb"));

        let waiting = Routes(std::collections::BTreeMap::from([(
            build_path,
            serde_json::json!({"workflow_runs": []}),
        )]));
        let context = preview_context(&waiting, "base/repo", &event).unwrap();
        assert!(!context.proceed);
        assert!(context.note.unwrap().contains("not green yet"));
    }

    #[test]
    fn a_completed_build_resolves_its_exact_open_labeled_pull_request() {
        let sha = "c".repeat(40);
        let event = serde_json::json!({
            "workflow_run": {
                "event": "pull_request",
                "conclusion": "success",
                "head_sha": sha,
                "head_repository": {"full_name": "base/repo"},
            },
        });
        let api = Routes(std::collections::BTreeMap::from([
            (
                format!("repos/base/repo/commits/{sha}/pulls?per_page=100&page=1"),
                serde_json::json!([{
                    "number": 8,
                    "state": "open",
                    "head": {"sha": sha, "repo": {"full_name": "base/repo"}},
                }]),
            ),
            (
                "repos/base/repo/pulls/8".into(),
                serde_json::json!({
                    "number": 8,
                    "state": "open",
                    "head": {"sha": sha, "repo": {"full_name": "base/repo"}},
                    "base": {"ref": "main"},
                    "labels": [{"name": "preview"}],
                }),
            ),
        ]));
        let context = preview_context(&api, "base/repo", &event).unwrap();
        assert!(context.proceed);
        assert_eq!(context.pull_request, Some(8));
        assert_eq!(context.tag.as_deref(), Some("pr8.gccccccc"));
    }
}
