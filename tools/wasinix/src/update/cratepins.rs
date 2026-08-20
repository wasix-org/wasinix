//! The concrete fork version set the crate mint publishes.
//!
//! Which upstream releases we mint is a constraint per crate, not a list: the
//! set is re-resolved against the crates.io index so a new matching release is
//! picked up and a yanked one drops out. Each resolved version carries the
//! hash of its upstream .crate.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;

use crate::support::error::{Result, request_error};
use crate::support::nix::{Flake, eval};

static SEMVER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(\d+)\.(\d+)\.(\d+)(?:\+[0-9A-Za-z.-]+)?$").unwrap());
static TERM: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*(>=|<=|=|<|>)\s*(\S+)\s*$").unwrap());

pub type Pins = BTreeMap<String, BTreeMap<String, String>>;
pub type Constraints = BTreeMap<String, Vec<String>>;

fn key(version: &str) -> Option<(u64, u64, u64)> {
    let captured = SEMVER.captures(version)?;
    Some((
        captured[1].parse().ok()?,
        captured[2].parse().ok()?,
        captured[3].parse().ok()?,
    ))
}

/// A version satisfies any one constraint (OR); a constraint is a
/// comma-separated AND of comparators.
pub fn matches(constraints: &[String], version: &str) -> Result<bool> {
    let Some(candidate) = key(version) else {
        return Ok(false);
    };
    for constraint in constraints {
        let mut satisfied = true;
        for term in constraint.split(',') {
            if term.trim() == "*" {
                continue;
            }
            let Some(captured) = TERM.captures(term) else {
                return request_error(format!(
                    "crate-pins: bad constraint term {term:?} in {constraint:?}"
                ));
            };
            let Some(bound) = key(&captured[2]) else {
                return request_error(format!("crate-pins: bad version in {constraint:?}"));
            };
            satisfied &= match &captured[1] {
                ">=" => candidate >= bound,
                "<=" => candidate <= bound,
                "=" => version == &captured[2],
                "<" => candidate < bound,
                ">" => candidate > bound,
                _ => false,
            };
        }
        if satisfied {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Non-yanked plain-semver releases, low to high. A line that does not parse
/// fails the read: a truncated index response silently pruning live versions
/// from crates.json is how pinned consumers break.
fn crates_io_releases(name: &str) -> Result<Vec<String>> {
    let url = format!(
        "https://index.crates.io/{}",
        crate::registries::cargo::index_path(name)
    );
    let body = crate::support::http::get_text(&url)?;
    let mut versions = Vec::new();
    for line in body.lines().filter(|line| !line.trim().is_empty()) {
        let entry: serde_json::Value =
            serde_json::from_str(line).map_err(|source| crate::support::error::Error::Json {
                path: format!("<crates.io index for {name}>").into(),
                source,
            })?;
        if entry["yanked"].as_bool().unwrap_or(false) {
            continue;
        }
        if let Some(version) = entry["vers"].as_str() {
            if SEMVER.is_match(version) {
                versions.push(version.to_string());
            }
        }
    }
    versions.sort_by_key(|version| key(version));
    Ok(versions)
}

/// The upstream .crate's hash, in SRI form.
fn sri(crate_name: &str, version: &str) -> Result<String> {
    let url = format!("https://static.crates.io/crates/{crate_name}/{version}/download");
    let output = crate::support::nix::Invocation::tool("nix-prefetch-url")
        .args(["--unpack", "--type", "sha256"])
        .operand(&url)
        .probe("a failed prefetch names the crate")?;
    if !output.status.is_success() {
        return request_error(format!(
            "prefetch of {crate_name} {version} failed: {}",
            output.stderr.trim()
        ));
    }
    let raw = String::from_utf8_lossy(&output.stdout)
        .trim()
        .lines()
        .last()
        .unwrap_or_default()
        .to_string();
    let converted = crate::support::nix::Invocation::plain("hash convert")
        .args(["--hash-algo", "sha256", "--to", "sri"])
        .operand(&raw)
        .checked_text(&format!("hash convert for {crate_name} {version}"))?;
    Ok(converted.trim().to_string())
}

pub fn resolve(constraints: &Constraints) -> Result<BTreeMap<String, Vec<String>>> {
    let mut wanted = BTreeMap::new();
    for (crate_name, constraint) in constraints {
        // No floor logic: the mint decides which versions resolve to an edit,
        // and a matched version that turns out stock is simply not minted.
        let mut versions = Vec::new();
        for version in crates_io_releases(crate_name)? {
            if matches(constraint, &version)? {
                versions.push(version);
            }
        }
        wanted.insert(crate_name.clone(), versions);
    }
    Ok(wanted)
}

pub fn run(repo: &Path, refresh: bool) -> Result<String> {
    let path = repo.join("pkgs/cargo-registry/crates.json");
    // Only a genuinely absent file starts empty; an unreadable or corrupt one
    // must not read as "no pins" and rewrite the world.
    let current: Pins = match std::fs::read_to_string(&path) {
        Ok(text) => {
            serde_json::from_str(&text).map_err(|source| crate::support::error::Error::Json {
                path: path.clone(),
                source,
            })?
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Pins::new(),
        Err(error) => return Err(crate::support::error::io(&path, error)),
    };
    let constraints: Constraints = crate::support::json::from_value(
        eval(&Flake::default(), "cargoRegistry.pinConstraints", None)?,
        "cargoRegistry.pinConstraints",
    )?;
    let wanted = resolve(&constraints)?;

    let todo: Vec<(String, String)> = wanted
        .iter()
        .flat_map(|(crate_name, versions)| {
            versions.iter().map(move |version| (crate_name, version))
        })
        .filter(|(crate_name, version)| {
            refresh
                || !current
                    .get(*crate_name)
                    .is_some_and(|known| known.contains_key(*version))
        })
        .map(|(crate_name, version)| (crate_name.clone(), version.clone()))
        .collect();

    let mut fetched: Pins = Pins::new();
    for (crate_name, version) in &todo {
        crate::support::ui::fact("fetching", format!("{crate_name} {version}"));
        let hash = sri(crate_name, version)?;
        fetched
            .entry(crate_name.clone())
            .or_default()
            .insert(version.clone(), hash);
    }

    let mut out = Pins::new();
    for (crate_name, versions) in &wanted {
        let mut by_version = BTreeMap::new();
        for version in versions {
            let hash = fetched
                .get(crate_name)
                .and_then(|new| new.get(version))
                .or_else(|| current.get(crate_name).and_then(|old| old.get(version)));
            let Some(hash) = hash else {
                return request_error(format!("no hash for {crate_name} {version}"));
            };
            by_version.insert(version.clone(), hash.clone());
        }
        out.insert(crate_name.clone(), by_version);
    }

    let pruned: Vec<String> = current
        .iter()
        .flat_map(|(crate_name, versions)| {
            versions.keys().map(move |version| (crate_name, version))
        })
        .filter(|(crate_name, version)| {
            !wanted
                .get(*crate_name)
                .is_some_and(|kept| kept.contains(version))
        })
        .map(|(crate_name, version)| format!("{crate_name} {version}"))
        .collect();

    crate::support::json::write(&path, &out)?;

    let total: usize = out.values().map(BTreeMap::len).sum();
    let mut line = format!("crate-pins: {total} pins ({} fetched)", todo.len());
    if !pruned.is_empty() {
        line += &format!(", pruned {}", pruned.join(", "));
    }
    Ok(line)
}
