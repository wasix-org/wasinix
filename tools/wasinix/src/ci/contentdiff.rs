//! Whether rebuilt outputs actually changed content. A moved derivation says
//! only that something upstream changed; two builds can differ in every store
//! path and still be bit-identical once self-references are rewritten.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::ci::evalmap::EvalMap;
use crate::support::atoms::JobAddr;
use crate::support::nix::Invocation;

const NARINFO_CHUNK: usize = 100;
/// Normalizing realises and rewrites both sides, which is far more expensive
/// than a hash comparison.
const MAX_NORMALIZE: usize = 25;
const NAR_SIZE_CAP: u64 = 256 * 1024 * 1024;

/// One output compared across the two sides.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Pair {
    pub attr: JobAddr,
    pub output: String,
    pub old: String,
    pub new: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Skipped {
    #[serde(flatten)]
    pub pair: Pair,
    pub reason: String,
}

/// The content comparison's outcome. It carries no status of its own: whether
/// the comparison ran to completion is the task's exit status, and a summary
/// only exists when it did.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentSummary {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub identical: Vec<Pair>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub changed: Vec<Pair>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub skipped: Vec<Skipped>,
    /// Rebuilt jobs that failed to build, so they had no output to compare.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub not_built: usize,
    /// Moved jobs excluded as content-free (validation checks).
    #[serde(default, skip_serializing_if = "is_zero")]
    pub excluded: usize,
}

fn is_zero(value: &usize) -> bool {
    *value == 0
}

impl ContentSummary {
    pub fn pair_count(&self) -> usize {
        self.identical.len() + self.changed.len() + self.skipped.len()
    }
}

fn basename(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Narinfo per store path, chunked and tolerant: nix path-info fails the
/// whole invocation when any queried path is absent, so a failed chunk
/// bisects until each missing path costs only itself, never its chunkmates.
fn path_infos(paths: &[String], store: Option<&str>) -> BTreeMap<String, Option<Value>> {
    fn query(
        chunk: &[String],
        store: Option<&str>,
        infos: &mut BTreeMap<String, Option<Value>>,
    ) {
        let mut invocation = Invocation::plain("path-info")
            .json()
            .args(["--json-format", "2"])
            .operands(chunk.iter().cloned());
        if let Some(store) = store {
            invocation = invocation.args(["--store", store]);
        }
        match invocation.probe("a missing path must not lose the comparison") {
            Ok(output) if output.status.is_success() => {
                if let Ok(value) = serde_json::from_slice::<Value>(&output.stdout) {
                    for (key, info) in value["info"].as_object().into_iter().flatten() {
                        infos.insert(
                            key.clone(),
                            if info.is_null() {
                                None
                            } else {
                                Some(info.clone())
                            },
                        );
                    }
                }
            }
            _ if chunk.len() > 1 => {
                let (left, right) = chunk.split_at(chunk.len() / 2);
                query(left, store, infos);
                query(right, store, infos);
            }
            result => {
                if let Ok(output) = result {
                    crate::support::ui::warning(format!(
                        "path-info: {}: {}",
                        basename(&chunk[0]),
                        output.stderr.trim().lines().last().unwrap_or_default()
                            .chars().take(160).collect::<String>()
                    ));
                }
                infos.insert(basename(&chunk[0]).to_string(), None);
            }
        }
    }
    let mut infos = BTreeMap::new();
    for chunk in paths.chunks(NARINFO_CHUNK) {
        query(chunk, store, &mut infos);
    }
    infos
}

/// Look locally first, then in the cache: a case built elsewhere has nothing
/// on this machine.
fn available_infos(paths: &[String], store: Option<&str>) -> BTreeMap<String, Option<Value>> {
    let mut local = path_infos(paths, None);
    let missing: Vec<String> = paths
        .iter()
        .filter(|path| local.get(basename(path)).is_none_or(Option::is_none))
        .cloned()
        .collect();
    if missing.is_empty() {
        return local;
    }
    let mut remote = path_infos(&missing, Some(store.unwrap_or(crate::support::nix::CACHE_SUBSTITUTER)));
    if store.is_some() {
        let still: Vec<String> = missing
            .iter()
            .filter(|path| remote.get(basename(path)).is_none_or(Option::is_none))
            .cloned()
            .collect();
        if !still.is_empty() {
            remote.extend(path_infos(&still, Some(crate::support::nix::CACHE_SUBSTITUTER)));
        }
    }
    for (key, value) in remote {
        if value.is_some() || !local.contains_key(&key) {
            local.insert(key, value);
        }
    }
    local
}

fn self_referential(path: &str, info: &Value) -> bool {
    info["references"]
        .as_array()
        .map(|refs| {
            refs.iter()
                .filter_map(Value::as_str)
                .any(|reference| basename(reference) == basename(path))
        })
        .unwrap_or(false)
}

/// Realise both sides and compare with self-references rewritten to content
/// hashes, which is the only way two self-referential outputs can be equal.
fn normalize_pair(old: &str, new: &str, store: Option<&str>) -> (Option<bool>, Option<String>) {
    let tail = |text: &str| {
        text.trim()
            .lines()
            .last()
            .unwrap_or_default()
            .chars()
            .take(120)
            .collect::<String>()
    };
    // Raw nix-store does not read the flake's nixConfig, so the cache is
    // named explicitly from the one place it is spelled.
    let realised = match store {
        Some(store) => Invocation::plain("copy")
            .args(["--from", store])
            .operands([old, new]),
        None => Invocation::tool("nix-store")
            .arg("--realise")
            .option(
                "extra-substituters",
                crate::support::nix::CACHE_SUBSTITUTER,
            )
            .option(
                "extra-trusted-public-keys",
                crate::support::nix::CACHE_PUBLIC_KEY,
            )
            .operands([old, new]),
    }
    .probe("a failed realise fails this pair, not the diff");
    match realised {
        Ok(output) if output.status.is_success() => {}
        Ok(output) => return (None, Some(format!("realise failed: {}", tail(&output.stderr)))),
        Err(error) => return (None, Some(format!("realise failed: {error}"))),
    }
    let output = match Invocation::plain("store make-content-addressed")
        .json()
        .operands([old, new])
        .probe("a failed normalize fails this pair, not the diff")
    {
        Ok(output) if output.status.is_success() => output,
        Ok(output) => {
            return (
                None,
                Some(format!(
                    "normalize failed: {}",
                    tail(&output.stderr)
                )),
            )
        }
        Err(error) => return (None, Some(format!("normalize failed: {error}"))),
    };
    let Ok(value) = serde_json::from_slice::<Value>(&output.stdout) else {
        return (None, Some("normalize produced no rewrites".into()));
    };
    let rewrites = &value["rewrites"];
    (Some(rewrites[old] == rewrites[new]), None)
}

fn compare_all(pairs: Vec<Pair>, store: Option<&str>) -> ContentSummary {
    let olds = available_infos(
        &pairs
            .iter()
            .map(|pair| pair.old.clone())
            .collect::<Vec<_>>(),
        store,
    );
    let news = available_infos(
        &pairs
            .iter()
            .map(|pair| pair.new.clone())
            .collect::<Vec<_>>(),
        store,
    );
    let mut result = ContentSummary::default();
    let mut normalized = 0;
    let skip = |result: &mut ContentSummary, pair: &Pair, reason: String| {
        result.skipped.push(Skipped {
            pair: pair.clone(),
            reason,
        });
    };

    for pair in &pairs {
        let old_info = olds.get(basename(&pair.old)).and_then(Option::as_ref);
        let new_info = news.get(basename(&pair.new)).and_then(Option::as_ref);
        if pair.old == pair.new {
            result.identical.push(pair.clone());
            continue;
        }
        let (Some(old_info), Some(new_info)) = (old_info, new_info) else {
            let side = if old_info.is_none() { "base" } else { "new" };
            skip(&mut result, pair, format!("{side} output not available"));
            continue;
        };
        if old_info["narHash"] == new_info["narHash"] {
            result.identical.push(pair.clone());
        } else if !self_referential(&pair.old, old_info) && !self_referential(&pair.new, new_info)
        {
            result.changed.push(pair.clone());
        } else if old_info["narSize"]
            .as_u64()
            .unwrap_or(0)
            .max(new_info["narSize"].as_u64().unwrap_or(0))
            > NAR_SIZE_CAP
        {
            skip(
                &mut result,
                pair,
                "self-referential and too large to normalize".into(),
            );
        } else if normalized >= MAX_NORMALIZE {
            skip(
                &mut result,
                pair,
                format!("normalize cap ({MAX_NORMALIZE}) reached"),
            );
        } else {
            normalized += 1;
            match normalize_pair(&pair.old, &pair.new, store) {
                (Some(true), _) => result.identical.push(pair.clone()),
                (Some(false), _) => result.changed.push(pair.clone()),
                (None, reason) => skip(&mut result, pair, reason.unwrap_or_default()),
            }
        }
    }
    result
}

/// Jobs whose derivation moved and whose outputs are worth comparing.
/// Validation checks emit success tokens, which carry no content.
pub fn content_jobs(
    base: &EvalMap,
    head: &EvalMap,
    allowed: Option<&BTreeSet<String>>,
) -> (Vec<String>, usize) {
    let moved: Vec<String> = head
        .jobs
        .iter()
        .filter(|(attr, drv)| {
            base.jobs.get(attr.as_str()).is_some_and(|old| old != *drv)
                && allowed.is_none_or(|allowed| allowed.contains(attr.as_str()))
        })
        .map(|(attr, _)| attr.as_str().to_string())
        .collect();
    let included: Vec<String> = moved
        .iter()
        .filter(|attr| {
            head.info
                .get(attr.as_str())
                .map(|info| info.content_diff)
                .unwrap_or_else(|| !attr.starts_with("checks."))
        })
        .cloned()
        .collect();
    let excluded = moved.len() - included.len();
    (included, excluded)
}

/// The output pairs a run can compare: every shared output of the jobs that
/// moved, built on both sides.
pub fn pairs_of(
    base: &EvalMap,
    head: &EvalMap,
    jobs: &[String],
    failed: &BTreeSet<String>,
) -> Vec<Pair> {
    jobs.iter()
        .filter(|attr| !failed.contains(attr.as_str()))
        .flat_map(|attr| {
            let old_outputs = base.outputs.get(attr.as_str()).cloned().unwrap_or_default();
            let new_outputs = head.outputs.get(attr.as_str()).cloned().unwrap_or_default();
            new_outputs
                .into_iter()
                .filter_map(|(name, new)| {
                    let old = old_outputs.get(&name)?.clone();
                    (!old.is_empty() && !new.is_empty()).then_some(Pair {
                        attr: JobAddr(attr.clone()),
                        output: name,
                        old,
                        new,
                    })
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

pub struct Request<'a> {
    pub base_map: &'a EvalMap,
    pub head_map: &'a EvalMap,
    pub junit: &'a [std::path::PathBuf],
    pub allowed_jobs: Option<&'a BTreeSet<String>>,
    /// Probe this store before the public cache, which is where a
    /// store-routed build left its outputs.
    pub store: Option<&'a str>,
}

/// Attrs whose build or evaluation failed have no new output to compare. An
/// upload failure still produced one.
fn failed_attrs(junit: &[std::path::PathBuf]) -> BTreeSet<String> {
    crate::ci::compare::junit_status(junit)
        .into_iter()
        .filter(|(_, status)| *status == crate::support::atoms::JobStatus::Failure)
        .map(|(attr, _)| attr.0)
        .collect()
}

pub fn run(request: &Request<'_>) -> ContentSummary {
    let (jobs, excluded) = content_jobs(request.base_map, request.head_map, request.allowed_jobs);
    let failed = failed_attrs(request.junit);
    let not_built = jobs.iter().filter(|attr| failed.contains(attr.as_str())).count();
    let pairs = pairs_of(request.base_map, request.head_map, &jobs, &failed);
    let mut summary = if pairs.is_empty() {
        ContentSummary::default()
    } else {
        compare_all(pairs, request.store)
    };
    summary.not_built = not_built;
    summary.excluded = excluded;
    summary
}
