//! Publication release numbers.
//!
//! A package republished at the same upstream version needs a new release
//! number, because both registries refuse to overwrite. The state file is
//! keyed by attribute path then upstream version, and an absent entry means 1.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::support::error::{Result, request_error, require};
use crate::support::naming::{self, Domain};
use crate::support::nix::{Flake, eval};

/// The roots `relVersions` is assembled from. A key is one of these plus a
/// package name, and that name may itself hold a dot (`python3.14`), so the
/// segments are cut here rather than by splitting the key.
const ROOTS: [&str; 3] = [
    "pythonRegistry.wheels",
    "wasmerPackages",
    "cargoRegistry.crates",
];

pub type Rels = BTreeMap<String, BTreeMap<String, u32>>;
/// Package -> the upstream versions it currently serves.
pub type Served = BTreeMap<String, Vec<String>>;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Info {
    pub versions: Vec<String>,
    pub kind: String,
    pub changelogs: BTreeMap<String, Option<String>>,
    pub derivations: BTreeMap<String, Vec<String>>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Bump {
    pub package: String,
    pub version: String,
    pub before: u32,
    pub after: u32,
    pub kind: String,
    pub changelog: Option<String>,
}

pub fn path(repo: &Path) -> PathBuf {
    repo.join("release-revisions.json")
}

pub fn load(repo: &Path) -> Result<Rels> {
    crate::support::json::read(&path(repo))
}

pub fn store(repo: &Path, rels: &Rels) -> Result<()> {
    crate::support::json::write(&path(repo), rels)
}

pub fn served() -> Result<Served> {
    crate::support::json::from_value(eval(&Flake::default(), "relVersions", None)?, "relVersions")
}

pub fn info() -> Result<BTreeMap<String, Info>> {
    crate::support::json::from_value(eval(&Flake::default(), "relInfo", None)?, "relInfo")
}

fn info_from(flake: &Flake<'_>) -> Result<BTreeMap<String, Info>> {
    crate::support::json::from_value(eval(flake, "relInfo", None)?, "relInfo")
}

pub fn changed(repo: &Path, reference: &str) -> Result<Vec<String>> {
    let current = info()?;
    let base = crate::ci::workspace::Worktree::add(repo, reference)?;
    let flake = format!("path:{}", base.path().display());
    let prior = info_from(&Flake(&flake))?;
    let mut selected = Vec::new();
    let mut unsupported = Vec::new();
    for (name, publication) in &current {
        let Some(before) = prior.get(name) else {
            continue;
        };
        for version in &publication.versions {
            if !before.versions.contains(version)
                || publication.derivations.get(version) == before.derivations.get(version)
            {
                continue;
            }
            let spec = format!("{name}@{version}");
            if publication.kind == "webc" {
                unsupported.push(spec);
            } else {
                selected.push(spec);
            }
        }
    }
    if !unsupported.is_empty() {
        return request_error(format!(
            "changed WebCs cannot be republished by a rel bump: {}",
            unsupported.join(", ")
        ));
    }
    require(
        !selected.is_empty(),
        "no same-version publication derivations changed",
    )?;
    Ok(selected)
}

/// The rels keys a caller can name. A key already is an attr path, with the
/// interpreter left out because one rel covers every interpreter.
pub fn domain(served: &Served) -> Domain {
    let mut domain = Domain::new(".#relVersions");
    for key in served.keys() {
        for root in ROOTS {
            if let Some(name) = key.strip_prefix(&format!("{root}.")) {
                let mut path: Vec<String> = root.split('.').map(str::to_string).collect();
                path.push(name.to_string());
                domain.add_path(path, key, None, Vec::new());
            }
        }
    }
    domain
}

/// Which (package, version) pairs a set of specs selects. Bumping every
/// version a package serves stays deliberate: registry history means one
/// package can serve several, and they are republished independently.
pub fn select(
    specs: &[String],
    served: &Served,
    all_versions: bool,
) -> Result<Vec<(String, String)>> {
    let mut targets: Vec<(String, String)> = Vec::new();
    for resolved in naming::resolve_all(&domain(served), specs)? {
        let key = resolved.key;
        let versions = &served[&key];
        let mut sorted = versions.clone();
        sorted.sort();
        match resolved.value {
            Some(picked) => {
                if !versions.contains(&picked) {
                    return request_error(format!(
                        "{key}@{picked}: not served (has {})",
                        sorted.join(", ")
                    ));
                }
                targets.push((key, picked));
            }
            None if all_versions => {
                targets.extend(
                    versions
                        .iter()
                        .map(|version| (key.clone(), version.clone())),
                );
            }
            None if versions.len() == 1 => targets.push((key, versions[0].clone())),
            None => {
                let options: Vec<String> = sorted
                    .iter()
                    .map(|version| format!("{key}@{version}"))
                    .collect();
                return request_error(format!(
                    "{key}: serves several versions, pick one: {}",
                    options.join(", ")
                ));
            }
        }
    }
    targets.dedup();
    Ok(targets)
}

pub fn bump(repo: &Path, specs: &[String], all_versions: bool) -> Result<Vec<Bump>> {
    let info = info()?;
    let served: Served = info
        .iter()
        .map(|(name, info)| (name.clone(), info.versions.clone()))
        .collect();
    let targets = select(specs, &served, all_versions)?;
    let mut rels = load(repo)?;
    let mut lines = Vec::new();
    for (key, version) in targets {
        let current = rels
            .get(&key)
            .and_then(|by_version| by_version.get(&version))
            .copied()
            .unwrap_or(1);
        rels.entry(key.clone())
            .or_default()
            .insert(version.clone(), current + 1);
        let package = &info[&key];
        let changelog = package.changelogs.get(&version).cloned().flatten();
        lines.push(Bump {
            package: key,
            version,
            before: current,
            after: current + 1,
            kind: package.kind.clone(),
            changelog,
        });
    }
    store(repo, &rels)?;
    Ok(lines)
}
