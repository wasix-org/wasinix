//! Reading and writing the documents the tool leaves behind: every file is
//! sorted, pretty-printed, newline-terminated, and written atomically, so a
//! run directory diffs line by line and a reader never sees a torn document.

use std::path::Path;

use serde::de::DeserializeOwned;

use crate::support::error::{Error, Result};

fn render<T: serde::Serialize>(value: &T) -> Result<String> {
    // Through `Value` so keys come out sorted; sorted keys are what make the
    // diffs readable.
    let normalized = serde_json::to_value(value).map_err(|source| Error::Json {
        path: "<in-memory>".into(),
        source,
    })?;
    let mut text = serde_json::to_string_pretty(&normalized).map_err(|source| Error::Json {
        path: "<in-memory>".into(),
        source,
    })?;
    text.push('\n');
    Ok(text)
}

pub fn write<T: serde::Serialize>(path: &Path, value: &T) -> Result<()> {
    let text = render(value)?;
    crate::support::fs::write_atomic(path, text.as_bytes())
}

pub(in crate::support) fn print<T: serde::Serialize>(value: &T) -> Result<()> {
    print!("{}", render(value)?);
    Ok(())
}

/// Decode an in-memory value, naming the context a failure reports.
pub fn from_value<T: DeserializeOwned>(value: serde_json::Value, context: &str) -> Result<T> {
    serde_json::from_value(value).map_err(|source| Error::Json {
        path: format!("<{context}>").into(),
        source,
    })
}

pub fn read<T: DeserializeOwned>(path: &Path) -> Result<T> {
    let text = crate::support::fs::read_to_string(path)?;
    serde_json::from_str(&text).map_err(|source| Error::Json {
        path: path.to_path_buf(),
        source,
    })
}
