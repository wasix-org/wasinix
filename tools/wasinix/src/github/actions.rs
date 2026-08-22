//! The GitHub Actions file boundary. Step outputs are scalar records, so a
//! value containing a line break is invalid rather than a second record.

use std::io::Write;
use std::path::Path;

use crate::support::error::{Error, Result};

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
}
