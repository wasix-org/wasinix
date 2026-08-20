//! Ephemeral static sites on Wasmer Edge: one deploy shape for every
//! registry preview, so each cell only supplies its built site and app name.

use std::path::Path;
use std::process::Command;

use serde_json::Value;

use crate::support::error::{Result, request_error};

pub struct Site<'a> {
    /// The built directory to serve as the app's public root.
    pub site: &'a Path,
    pub app: &'a str,
    pub owner: &'a str,
    pub registry: &'a str,
}

/// Deploy the site as an ephemeral Edge app and return its URL. One app per
/// pull request; preview-cleanup deletes it when the PR closes.
pub fn preview_site(request: Site<'_>) -> Result<String> {
    let scratch = crate::support::fs::Scratch::create("wasinix-preview")?;
    crate::support::fs::copy_tree(request.site, &scratch.path().join("site"), Some(0o644))?;
    crate::support::fs::write(
        &scratch.path().join("wasmer.toml"),
        b"[dependencies]\n\"wasmer/static-web-server\" = \"*\"\n\n[fs]\n\"/public\" = \"site\"\n",
    )?;
    crate::support::fs::write(
        &scratch.path().join("app.yaml"),
        format!(
            "kind: wasmer.io/App.v0\nname: {}\nowner: {}\npackage: .\n",
            request.app, request.owner
        )
        .as_bytes(),
    )?;

    // --no-wait: an ephemeral preview does not need the reachability poll,
    // which errored after five minutes on a fresh app that had deployed fine.
    let mut deploy = Command::new("wasmer");
    deploy
        .args(["deploy", "--non-interactive", "--no-wait"])
        .args(["--registry", request.registry])
        .current_dir(scratch.path());
    crate::support::tools::log(&deploy);
    if !crate::support::tools::status(&mut deploy)?.success() {
        return request_error(format!(
            "deploying {}/{} failed",
            request.owner, request.app
        ));
    }

    let mut get = Command::new("wasmer");
    get.args(["app", "get", &format!("{}/{}", request.owner, request.app)])
        .args(["--registry", request.registry])
        .args(["--format", "json"]);
    let output = crate::support::tools::output(&mut get)?;
    if !output.status.success() {
        return request_error(format!(
            "reading back {}/{} failed: {}",
            request.owner,
            request.app,
            String::from_utf8_lossy(&output.stderr).trim()
        ));
    }
    let app: Value = serde_json::from_slice(&output.stdout).map_err(|source| {
        crate::support::error::Error::Json {
            path: "<wasmer app get>".into(),
            source,
        }
    })?;
    match app["url"].as_str() {
        Some(url) => Ok(url.to_string()),
        None => request_error("the deployed app reported no url"),
    }
}
