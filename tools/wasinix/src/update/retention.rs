//! The repo-wide steps a bump implies: retaining outgoing versions in the
//! registry history, pruning publication keys nothing serves, and the update
//! notes whose predicates fire.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;
use serde_json::Value;

use crate::support::error::{Result, request_error};
use crate::support::nix::{Invocation, SYSTEM, project_attr};
use crate::support::ui;
use crate::update::history::AddOutcome;

/// How far down the version a bump must move before the outgoing version is
/// retained in the registry-history table. The number is how many leading
/// components define a series.
fn retention_level(policy: &str) -> Option<usize> {
    match policy {
        "none" => Some(0),
        "major" => Some(1),
        "minor" => Some(2),
        _ => None,
    }
}

const DEFAULT_RETENTION: &str = "major";

/// Only plain dotted releases have comparable components. A non-release
/// version (bash 5.3p9, a 0-unstable-<date> pin) has no series to cross, and
/// treating its whole string as one would fire on every bump.
fn plain_release(value: &str) -> bool {
    !value.is_empty()
        && value
            .split('.')
            .all(|part| !part.is_empty() && part.chars().all(|c| c.is_ascii_digit()))
}

pub fn retention_crossed(prior: &str, now: &str, level: usize) -> bool {
    if level == 0 || !plain_release(prior) || !plain_release(now) {
        return false;
    }
    let head = |value: &str| value.split('.').take(level).collect::<Vec<_>>().join(".");
    head(prior) != head(now)
}

fn retention_note(prior: &str, level: usize) -> String {
    let series = prior.split('.').take(level).collect::<Vec<_>>().join(".");
    let which = if level == 1 { "major" } else { "minor" };
    format!("latest {series}.x (outgoing {which})")
}

#[derive(Debug, Clone, Deserialize)]
pub struct Served {
    pub version: String,
    pub history_spec: String,
    #[serde(default)]
    pub retention: Option<String>,
}

pub type Versions = BTreeMap<String, BTreeMap<String, Served>>;

/// The history spec a retention add uses, with a dotted leaf quoted the way
/// the address grammar spells it.
pub(crate) fn retention_add_spec(served: &Served) -> String {
    let spec = match served.history_spec.rsplit_once('.') {
        Some((root, leaf)) => crate::support::naming::quoted_attr(leaf)
            .map(|leaf| format!("{root}.{leaf}"))
            .unwrap_or_else(|_| served.history_spec.clone()),
        _ => served.history_spec.clone(),
    };
    format!("{spec}@{}", served.version)
}

const WHEEL_APPLY: &str = "builtins.mapAttrs (name: w: \
    { version = w.version; history_spec = \"packages.python.${name}\"; \
    retention = w.passthru.wasinix.retention or null; })";
fn cli_apply() -> String {
    "builtins.mapAttrs (name: p: { inherit name; \
     history_spec = \"packages.wasix.${name}\"; \
     shipped = p.passthru.wasinix.shipped or false; version = p.version; \
     retention = p.passthru.wasinix.retention or null; })"
        .to_string()
}

#[derive(Deserialize)]
struct EvaluatedNotes {
    ok: bool,
    value: Value,
}

#[derive(Deserialize)]
struct VersionState {
    wheels: Value,
    clis: Value,
    notes: EvaluatedNotes,
}

fn version_apply(include_notes: bool) -> String {
    let notes = if include_notes {
        "let n = builtins.tryEval p.internals.repository.updates.updateNotes.versions; in { ok = n.success; value = if n.success then n.value else {}; }"
    } else {
        "{ ok = true; value = {}; }"
    };
    format!(
        "p: {{ wheels = {{ py313 = ({WHEEL_APPLY}) p.artifacts.wheel-py313; py314 = ({WHEEL_APPLY}) p.artifacts.wheel-py314; }}; clis = ({}) p.packages.wasix.preferred; notes = {notes}; }}",
        cli_apply()
    )
}

fn evaluate_versions(repo: &Path, include_notes: bool) -> Result<VersionState> {
    let apply = version_apply(include_notes);
    let value = Invocation::flake("eval", format!(".#legacyPackages.{SYSTEM}"))
        .json()
        .apply(&apply)
        .workdir(repo)
        .run_json("served versions")?;
    crate::support::json::from_value(value, "served versions")
}

/// Current served versions, excluding the history entries themselves.
pub fn current_versions(repo: &Path) -> Result<Versions> {
    let state = evaluate_versions(repo, false)?;
    versions_from_state(repo, &state)
}

fn versions_from_state(repo: &Path, state: &VersionState) -> Result<Versions> {
    let mut result: Versions = BTreeMap::new();
    result.insert("wheel".into(), BTreeMap::new());
    result.insert("cli".into(), BTreeMap::new());
    let history: Value = crate::support::json::read(&crate::update::history::wheel_history(repo))?;
    let history_keys: std::collections::BTreeSet<String> = history
        .as_object()
        .into_iter()
        .flatten()
        .flat_map(|(attr, versions)| {
            versions
                .as_object()
                .into_iter()
                .flatten()
                .map(move |(version, _)| format!("{attr}-{version}"))
        })
        .collect();

    for (_, by_attr) in state.wheels.as_object().into_iter().flatten() {
        for (attr, info) in by_attr.as_object().into_iter().flatten() {
            if history_keys.contains(attr) {
                continue;
            }
            result
                .get_mut("wheel")
                .expect("the wheel bucket exists")
                .entry(attr.clone())
                .or_insert(crate::support::json::from_value(
                    info.clone(),
                    "Python wheel artifact versions",
                )?);
        }
    }

    for (name, info) in state.clis.as_object().into_iter().flatten() {
        if !info["shipped"].as_bool().unwrap_or(false) {
            continue;
        }
        result
            .get_mut("cli")
            .expect("the cli bucket exists")
            .entry(name.clone())
            .or_insert(crate::support::json::from_value(
                info.clone(),
                "preferred package versions",
            )?);
    }
    Ok(result)
}

pub fn prior_state(repo: &Path) -> Result<(Value, Versions)> {
    let state = evaluate_versions(repo, true)?;
    if !state.notes.ok {
        ui::warning("note version eval failed");
    }
    let versions = versions_from_state(repo, &state)?;
    Ok((state.notes.value, versions))
}

/// Retention keeps the outgoing version behind in the registry-history table
/// so pinned consumers keep resolving. Not keyed to a target: what matters is
/// that a served version moved, and a package pinning its own src moves on
/// its own updateScript rather than the nixpkgs bump.
pub fn regen_history(repo: &Path, priors: &Versions) -> Result<Option<String>> {
    if priors.is_empty() {
        return Ok(None);
    }
    let current = current_versions(repo)?;
    let mut lines = Vec::new();
    let mut failed = Vec::new();
    for (kind, by_attr) in priors {
        for (attr, prior) in by_attr {
            let Some(now) = current.get(kind).and_then(|c| c.get(attr)) else {
                continue;
            };
            let policy = now
                .retention
                .clone()
                .unwrap_or_else(|| DEFAULT_RETENTION.into());
            let Some(level) = retention_level(&policy) else {
                failed.push(format!(
                    "{attr}: unknown retention policy {policy:?} (expected one of none, major, minor)"
                ));
                continue;
            };
            if !retention_crossed(&prior.version, &now.version, level) {
                continue;
            }
            let appended = crate::update::history::add(
                repo,
                crate::update::history::AddCommand {
                    spec: retention_add_spec(prior),
                    per_major: false,
                    per_minor: false,
                    since: None,
                    project: None,
                    dry_run: false,
                    options: crate::update::history::AddOptions {
                        variants: None,
                        note: Some(retention_note(&prior.version, level)),
                        force: false,
                        skip_unsupported: true,
                    },
                },
            );
            // The rels prune runs after retention and drops the outgoing
            // version's key once nothing serves it; a skip or failure here is
            // exactly the state this stage exists to prevent, so it fails.
            match appended {
                Ok(backfill) => {
                    for (_, version, outcome) in backfill.outcomes {
                        match outcome {
                            AddOutcome::Added { .. } | AddOutcome::AlreadyPresent => {
                                lines.push(format!("{attr}@{version} retained"));
                            }
                            AddOutcome::CurrentVersion => {}
                            AddOutcome::Skipped { reason } => {
                                failed.push(format!("{attr}@{version}: {reason}"));
                            }
                        }
                    }
                }
                Err(error) => failed.push(format!("{attr}@{}: {error}", prior.version)),
            }
        }
    }
    if !failed.is_empty() {
        return request_error(failed.join("; "));
    }
    Ok((!lines.is_empty()).then(|| lines.join("; ")))
}

/// Publication release numbers are keyed by attr path then upstream version;
/// any bump that moves a package leaves its old key behind.
pub fn prune_rels(repo: &Path) -> Result<Option<String>> {
    let rels = crate::update::rels::load(repo)?;
    if rels.is_empty() {
        return Ok(None);
    }
    let served = crate::update::rels::served()?;
    let mut dropped = Vec::new();
    let mut pruned = crate::update::rels::Rels::new();
    for (key, by_version) in &rels {
        let keep: BTreeMap<String, u32> = by_version
            .iter()
            .filter(|(version, _)| {
                served
                    .get(key)
                    .is_some_and(|versions| versions.contains(version))
            })
            .map(|(version, rel)| (version.clone(), *rel))
            .collect();
        for version in by_version.keys() {
            if !keep.contains_key(version) {
                dropped.push(format!("{key} {version}"));
            }
        }
        if !keep.is_empty() {
            pruned.insert(key.clone(), keep);
        }
    }
    if dropped.is_empty() {
        return Ok(None);
    }
    crate::update::rels::store(repo, &pruned)?;
    Ok(Some(format!("dropped stale rels: {}", dropped.join(", "))))
}

#[derive(Debug, Clone, Deserialize)]
pub struct Note {
    #[serde(default)]
    pub name: String,
    pub message: String,
    #[serde(default)]
    pub prior: Option<String>,
    #[serde(default)]
    pub version: Option<String>,
}

fn fired_notes_once(repo: &Path, priors: &Value) -> Result<Value> {
    let output = crate::support::nix::Invocation::flake(
        "eval",
        format!(
            ".#{}",
            project_attr("internals.repository.updates.updateNotes.fired")
        ),
    )
    .json()
    .impure()
    .apply("f: f (builtins.fromJSON (builtins.getEnv \"NOTE_PRIORS\"))")
    .env("NOTE_PRIORS", priors.to_string())
    .workdir(repo)
    .probe("a failed note check reports its own stderr")?;
    if !output.status.is_success() {
        return request_error(format!("note check failed: {}", output.stderr.trim()));
    }
    serde_json::from_slice(&output.stdout).map_err(|source| crate::support::error::Error::Json {
        path: "<internals.repository.updates.updateNotes.fired>".into(),
        source,
    })
}

/// Notes whose predicate fires now that the pins moved. Advisory, with one
/// retry: a single transient eval failure must not silently drop the notes.
pub fn fired_notes(repo: &Path, priors: &Value) -> Vec<Note> {
    let fired = match fired_notes_once(repo, priors) {
        Ok(fired) => fired,
        Err(first) => match fired_notes_once(repo, priors) {
            Ok(fired) => fired,
            Err(second) => {
                ui::warning(format!("{first}; retry: {second}"));
                return Vec::new();
            }
        },
    };
    let mut seen: BTreeMap<String, Note> = BTreeMap::new();
    for (attr, notes) in fired.as_object().into_iter().flatten() {
        // artifacts.webc.<n>.webc names as <n>, which may contain dots.
        let base = attr.strip_suffix(".webc").unwrap_or(attr);
        let name = base
            .strip_prefix("artifacts.webc.")
            .map(str::to_string)
            .unwrap_or_else(|| base.rsplit('.').next().unwrap_or(base).to_string());
        for note in notes.as_array().into_iter().flatten() {
            let Ok(mut note) = serde_json::from_value::<Note>(note.clone()) else {
                continue;
            };
            note.name = name.clone();
            seen.entry(note.message.clone()).or_insert(note);
        }
    }
    seen.into_values().collect()
}

#[cfg(test)]
mod tests {
    use super::{VersionState, version_apply};
    use crate::support::nix::Invocation;

    #[test]
    fn one_package_set_evaluation_returns_every_prior_view() {
        let expression = format!(
            "let p = {{ \
             artifacts.wheel-py313.demo = {{ version = \"1\"; passthru.wasinix.retention = \"minor\"; }}; \
             artifacts.wheel-py314 = {{}}; \
             packages.wasix.preferred.cli = {{ version = \"2\"; passthru.wasinix = {{ shipped = true; retention = \"major\"; }}; }}; \
             internals.repository.updates.updateNotes.versions.cli = \"2\"; \
             }}; in ({}) p",
            version_apply(true)
        );
        let value = Invocation::expr("eval", expression)
            .option("experimental-features", "nix-command")
            .args(["--store", "dummy://"])
            .json()
            .run_json("combined update state")
            .unwrap();
        let state: VersionState = crate::support::json::from_value(value, "update state").unwrap();
        assert_eq!(state.wheels["py313"]["demo"]["version"], "1");
        assert_eq!(state.clis["cli"]["version"], "2");
        assert_eq!(state.notes.value["cli"], "2");
    }
}
