//! The GitHub Actions file boundary. Step outputs are scalar records, so a
//! value containing a line break is invalid rather than a second record.

use std::io::Write;
use std::path::Path;
use std::sync::LazyLock;

use crate::support::error::{Error, Result};

static REPOSITORY: LazyLock<regex::Regex> = LazyLock::new(|| {
    regex::Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$").unwrap()
});

pub const ARTIFACT_CI_RUN: &str = "ci-run";
pub const OUTPUT_BIN: &str = "bin";
pub const OUTPUT_COMMENT_ID: &str = "commentId";
pub const OUTPUT_HEAD_SHA: &str = "headSha";
pub const OUTPUT_KIND: &str = "kind";
pub const OUTPUT_MATRIX: &str = "matrix";
pub const OUTPUT_PULL_REQUEST: &str = "pullRequest";
pub const OUTPUT_REPORTED: &str = "reported";
pub const OUTPUT_RUN_DIR: &str = "runDir";
pub const OUTPUT_RUN_ID: &str = "runId";

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
}
