use std::path::PathBuf;

use crate::support::error::{request_error, Result};

/// Single-quote a string for a POSIX shell.
pub fn quote(text: &str) -> String {
    if !text.is_empty()
        && text
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"._-/=:@+".contains(&b))
    {
        return text.to_string();
    }
    format!("'{}'", text.replace('\'', r"'\''"))
}

pub fn home_dir() -> Result<PathBuf> {
    match crate::support::env::home() {
        Some(home) => Ok(home),
        None => request_error("$HOME is not set, so \"~\" paths cannot be resolved"),
    }
}

/// `~` and `~/...` expanded against $HOME; an unset $HOME is an error, never a
/// literal tilde handed to ssh.
pub fn expand_home(path: &str) -> Result<PathBuf> {
    if path == "~" {
        return home_dir();
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return Ok(home_dir()?.join(rest));
    }
    Ok(PathBuf::from(path))
}
