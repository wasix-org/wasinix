//! The completion name cache. Real evaluations refresh it; completers only
//! read it, so a keystroke never pays an evaluation and never errors. Each
//! project holds its own cache, so evaluating one never answers for another.

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::support::nix::ProjectRef;

/// The cache directory one project owns. A path flake ref is canonicalized
/// first, since `.` is the default ref and every checkout would otherwise
/// share one key.
fn project_key(project: &ProjectRef) -> String {
    let flake = if project.flake.starts_with(['.', '/']) {
        std::fs::canonicalize(&project.flake)
            .map(|path| path.display().to_string())
            .unwrap_or_else(|_| project.flake.clone())
    } else {
        project.flake.clone()
    };
    format!("{:x}", Sha256::digest(format!("{flake}#{}", project.attr)))
}

fn dir() -> Option<PathBuf> {
    let root = match crate::support::env::xdg_state_home() {
        Some(state) => state.join("wasinix/completions"),
        None => crate::support::shell::home_dir()
            .ok()?
            .join(".local/state/wasinix/completions"),
    };
    Some(root.join(project_key(crate::support::nix::project())))
}

fn record_at(dir: &Path, kind: &str, names: &[&str]) {
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }
    let mut text = String::with_capacity(names.len() * 24);
    for name in names {
        text.push_str(name);
        text.push('\n');
    }
    // Staged and renamed: a completer reading mid-write would offer a
    // truncated world.
    let staged = dir.join(format!("{kind}.tmp-{}", std::process::id()));
    if std::fs::write(&staged, text).is_ok() {
        let _ = std::fs::rename(&staged, dir.join(kind));
    }
}

fn recall_at(dir: &Path, kind: &str) -> Vec<String> {
    std::fs::read_to_string(dir.join(kind))
        .map(|text| text.lines().map(str::to_string).collect())
        .unwrap_or_default()
}

/// Record a name set, atomically and silently: completion data must never
/// fail the work that produced it. Inert under test, where fixture
/// evaluations would clobber the user's real catalog.
pub fn record<'a>(kind: &str, names: impl IntoIterator<Item = &'a str>) {
    if cfg!(test) {
        return;
    }
    let Some(dir) = dir() else { return };
    let names: Vec<&str> = names.into_iter().collect();
    record_at(&dir, kind, &names);
}

/// Recall a recorded set; empty until something evaluated.
pub fn recall(kind: &str) -> Vec<String> {
    let Some(dir) = dir() else {
        return Vec::new();
    };
    recall_at(&dir, kind)
}

/// How long ago a set was recorded, so a reader can state its staleness.
pub fn age(kind: &str) -> Option<std::time::Duration> {
    std::fs::metadata(dir()?.join(kind))
        .and_then(|meta| meta.modified())
        .ok()
        .and_then(|at| at.elapsed().ok())
}

#[cfg(test)]
pub(crate) fn project_key_for_tests(project: &ProjectRef) -> String {
    project_key(project)
}

#[cfg(test)]
pub(crate) fn round_trip_for_tests(dir: &Path, kind: &str, names: &[&str]) -> Vec<String> {
    record_at(dir, kind, names);
    recall_at(dir, kind)
}
