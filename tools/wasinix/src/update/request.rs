//! The contract between the update driver and a package's own update script.
//!
//! Most packages are bumped by nix-update alone. A package whose pin is
//! derived from another (a bootstrap compiler dictated by the fork's tag, a
//! lockfile that must match a fetched source) carries its own script, and that
//! script needs to know whether the driver asked for a specific release or
//! revision rather than "whatever is newest".

use serde::{Deserialize, Serialize};

use crate::support::error::{request_error, Result};

pub const REQUEST_ENV: &str = "WASINIX_UPDATE_REQUEST";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    /// Bump to a named upstream release.
    Release,
    /// Pin to a named commit, which has no release identity.
    Revision,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    pub schema: u32,
    pub mode: Mode,
    pub target: String,
    #[serde(default)]
    pub value: String,
    /// Where a revision came from, so the script can fetch it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<serde_json::Value>,
}

/// The driver's request, if this run has one. Absent means an ordinary
/// "bump to whatever is newest" update.
pub fn current(expected_target: Option<&str>) -> Result<Option<Request>> {
    match crate::support::env::update_request()? {
        Some(raw) => parse(&raw, expected_target).map(Some),
        None => Ok(None),
    }
}

/// Split from `current` so the shape rules are testable without the
/// environment, which is process-global.
pub fn parse(raw: &str, expected_target: Option<&str>) -> Result<Request> {
    let request: Request = serde_json::from_str(raw).map_err(|error| {
        crate::support::error::Error::Request(format!("invalid {REQUEST_ENV}: {error}"))
    })?;
    if request.schema != 1 {
        return request_error(format!("unsupported {REQUEST_ENV} value"));
    }
    if request.target.is_empty() {
        return request_error(format!("{REQUEST_ENV} has no target"));
    }
    if let Some(expected) = expected_target {
        if request.target != expected {
            return request_error(format!(
                "{REQUEST_ENV} targets {:?}, expected {expected:?}",
                request.target
            ));
        }
    }
    match request.mode {
        Mode::Release if request.value.is_empty() => {
            request_error(format!("{REQUEST_ENV} release request has no value"))
        }
        Mode::Revision if request.source.is_none() => {
            request_error(format!("{REQUEST_ENV} revision request has no source"))
        }
        _ => Ok(request),
    }
}

/// Apply an explicit request to the argv the package declared.
pub fn nix_update_argv(argv: &[String], request: Option<&Request>) -> Result<Vec<String>> {
    let Some(request) = request else {
        return Ok(argv.to_vec());
    };
    let requested = match request.mode {
        Mode::Release => format!("--version={}", request.value),
        Mode::Revision => {
            let revision = request
                .source
                .as_ref()
                .and_then(|source| source["rev"].as_str())
                .ok_or_else(|| {
                    crate::support::error::Error::Request(
                        "nix-update revision request has no revision".into(),
                    )
                })?;
            format!("--rev={revision}")
        }
    };
    let mut out = Vec::new();
    let mut index = 0;
    while index < argv.len() {
        let arg = &argv[index];
        if arg == "--version" || arg == "--rev" {
            index += 1;
            if index < argv.len() && !argv[index].starts_with('-') {
                index += 1;
            }
            continue;
        }
        if arg.starts_with("--version=") || arg.starts_with("--rev=") {
            index += 1;
            continue;
        }
        out.push(arg.clone());
        index += 1;
    }
    out.push(requested);
    Ok(out)
}
