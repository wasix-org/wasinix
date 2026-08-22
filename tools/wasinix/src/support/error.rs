use std::path::{Path, PathBuf};

use thiserror::Error;

use crate::support::process::CommandStatus;

/// Every failure carries enough context to act on: a path for filesystem and
/// document errors, the request text for caller mistakes. There is no bare
/// `From<io::Error>` on purpose; attach the path via [`io`] or the fs/json
/// helpers.
#[derive(Debug, Error)]
pub enum Error {
    /// A caller's request could not be accepted. Never a bug in the tool.
    #[error("{0}")]
    Request(String),
    /// A named thing does not exist (a run id, a remote name).
    #[error("{0}")]
    Missing(String),
    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("{path}: {source}")]
    Json {
        path: PathBuf,
        #[source]
        source: serde_json::Error,
    },
    #[error("{context}: {source}")]
    Http {
        context: String,
        #[source]
        source: Box<ureq::Error>,
    },
    /// An internal failure that is not the caller's fault.
    #[error("{0}")]
    Failure(String),
}

impl Error {
    pub fn status(&self) -> CommandStatus {
        match self {
            Error::Request(_) => CommandStatus::REQUEST_ERROR,
            Error::Missing(_) => CommandStatus::NOT_FOUND,
            _ => CommandStatus::FAILURE,
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;

pub fn request_error<T>(message: impl Into<String>) -> Result<T> {
    Err(Error::Request(message.into()))
}

pub fn missing<T>(message: impl Into<String>) -> Result<T> {
    Err(Error::Missing(message.into()))
}

pub fn io(path: impl AsRef<Path>, source: std::io::Error) -> Error {
    Error::Io {
        path: path.as_ref().to_path_buf(),
        source,
    }
}

pub fn require(condition: bool, message: impl Into<String>) -> Result<()> {
    if condition {
        Ok(())
    } else {
        Err(Error::Request(message.into()))
    }
}

pub fn finalize<T>(result: Result<T>, finished: Result<()>, context: &str) -> Result<T> {
    match (result, finished) {
        (result, Ok(())) => result,
        (Ok(_), Err(error)) => Err(error),
        (Err(error), Err(finish_error)) => Err(Error::Failure(format!(
            "{error}; {context}: {finish_error}"
        ))),
    }
}

/// One line of an error, short enough for a table cell or a summary line.
pub fn brief(error: &Error, limit: usize) -> String {
    error
        .to_string()
        .lines()
        .next()
        .unwrap_or("unknown error")
        .chars()
        .take(limit)
        .collect()
}

/// The end of a tool's output, which is where it says what went wrong. The
/// cut lands on a line boundary: a size-based one opens mid-token, and the
/// first thing a reader sees is then half a store path.
pub fn tail(text: &str, limit: usize) -> String {
    let text = text.trim();
    let start = text
        .char_indices()
        .rev()
        .take(limit)
        .last()
        .map(|(index, _)| index)
        .unwrap_or(0);
    let start = match text[start..].find('\n') {
        Some(at) if start > 0 => start + at + 1,
        _ => start,
    };
    text[start..].to_string()
}

#[cfg(test)]
mod tests {
    use super::{finalize, Error, Result};

    #[test]
    fn finalization_preserves_both_failures() {
        let result: Result<()> = Err(Error::Request("primary".to_string()));
        let finished = Err(Error::Failure("secondary".to_string()));
        assert_eq!(
            finalize(result, finished, "could not finish")
                .unwrap_err()
                .to_string(),
            "primary; could not finish: secondary"
        );
    }
}
