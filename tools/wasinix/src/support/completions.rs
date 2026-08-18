//! The completion name cache. Real evaluations refresh it; completers only
//! read it, so a keystroke never pays an evaluation and never errors.

use std::path::{Path, PathBuf};

fn dir() -> Option<PathBuf> {
    if let Some(state) = crate::support::env::xdg_state_home() {
        return Some(state.join("wasinix/completions"));
    }
    crate::support::shell::home_dir()
        .ok()
        .map(|home| home.join(".local/state/wasinix/completions"))
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
/// fail the work that produced it.
pub fn record<'a>(kind: &str, names: impl IntoIterator<Item = &'a str>) {
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

#[cfg(test)]
pub(crate) fn round_trip_for_tests(dir: &Path, kind: &str, names: &[&str]) -> Vec<String> {
    record_at(dir, kind, names);
    recall_at(dir, kind)
}
