//! What a git-sourced pin's upstream says about itself: which releases exist,
//! which commits are merged, and what version a commit calls itself.
//!
//! A release-tracked pin advances only to a newer release, so the questions
//! all need real history rather than a `ls-remote` answer: whether a manual
//! revision is merged, and whether a release still contains what the outgoing
//! pin carried. One bare blobless mirror per repository answers all of them
//! and is reused across runs.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::support::error::{Result, request_error};
use crate::support::git;

/// The branch a manual revision must be merged into. Releases are cut from
/// it, so a commit outside it has no release that will ever contain it.
pub const TRUNK: &str = "main";

/// A release version. Wasmer-style `vMAJOR.MINOR.PATCH`, with anything
/// carrying a prerelease suffix rejected rather than ordered: an `-rc.1` is
/// not a release and must never win the "newest" comparison.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
}

impl Version {
    /// Parse a release version, with or without the `v` prefix. `None` for a
    /// prerelease, a build-metadata suffix, or anything not three numbers:
    /// the caller wants those skipped, not diagnosed.
    pub fn parse(text: &str) -> Option<Version> {
        let text = text.strip_prefix('v').unwrap_or(text);
        if text.contains(['-', '+']) {
            return None;
        }
        let mut parts = text.split('.');
        let mut number = || parts.next()?.parse::<u64>().ok();
        let (major, minor, patch) = (number()?, number()?, number()?);
        parts.next().is_none().then_some(Version {
            major,
            minor,
            patch,
        })
    }
}

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)
    }
}

/// A release tag and the commit it names.
#[derive(Debug, Clone)]
pub struct Release {
    pub version: Version,
    pub tag: String,
    pub rev: String,
}

/// The clone url a target's source names.
pub fn source_repository(source: &Value) -> Option<String> {
    match source["kind"].as_str()? {
        "github" => Some(format!(
            "https://github.com/{}/{}.git",
            source["owner"].as_str()?,
            source["repo"].as_str()?
        )),
        "git" => source["url"].as_str().map(str::to_string),
        _ => None,
    }
}

fn mirror_root() -> Result<PathBuf> {
    let root = match crate::support::env::xdg_state_home() {
        Some(state) => state.join("wasinix/upstream"),
        None => crate::support::shell::home_dir()?.join(".local/state/wasinix/upstream"),
    };
    Ok(root)
}

/// A stable directory name for a clone url, so the mirror is reused rather
/// than re-cloned. Non-word bytes collapse to `-`; the url stays readable in
/// the path, which matters when someone has to inspect the cache by hand.
fn mirror_key(repository: &str) -> String {
    let mut key = String::with_capacity(repository.len());
    for c in repository.trim_end_matches(".git").chars() {
        if c.is_ascii_alphanumeric() {
            key.push(c);
        } else if !key.ends_with('-') {
            key.push('-');
        }
    }
    key.trim_matches('-').to_string()
}

/// A bare blobless mirror of `repository`, cloned once and refreshed after.
/// Blobless keeps the clone small while still allowing `git show` to fetch
/// the one file a version read needs.
pub fn mirror(repository: &str) -> Result<PathBuf> {
    let dir = mirror_root()?.join(mirror_key(repository));
    if dir.join("HEAD").exists() {
        git::git_logged(&dir, &["fetch", "--prune", "--tags", "origin"])?;
        return Ok(dir);
    }
    crate::support::fs::create_dir_all(&mirror_root()?)?;
    git::git_global(&[
        "clone",
        "--bare",
        "--filter=blob:none",
        repository,
        &dir.to_string_lossy(),
    ])?;
    Ok(dir)
}

/// Every release the mirror knows, oldest first. Prereleases are dropped:
/// `Version::parse` refuses them, so an `-rc` tag cannot be selected as the
/// newest release by accident.
pub fn releases(mirror: &Path) -> Result<Vec<Release>> {
    let output = git::git(mirror, &["show-ref", "--dereference", "--tags"])?;
    let mut found: Vec<Release> = Vec::new();
    for line in output.lines() {
        let Some((rev, reference)) = line.split_once(' ') else {
            continue;
        };
        // An annotated tag lists the tag object and, as `^{}`, the commit.
        // Take the dereferenced line and let it replace the tag object's.
        let dereferenced = reference.ends_with("^{}");
        let reference = reference.trim_end_matches("^{}");
        let Some(tag) = reference.strip_prefix("refs/tags/") else {
            continue;
        };
        let Some(version) = Version::parse(tag) else {
            continue;
        };
        match found.iter_mut().find(|release| release.tag == tag) {
            Some(existing) if dereferenced => existing.rev = rev.to_string(),
            Some(_) => {}
            None => found.push(Release {
                version,
                tag: tag.to_string(),
                rev: rev.to_string(),
            }),
        }
    }
    found.sort_by_key(|release| release.version);
    Ok(found)
}

/// The version a commit calls itself, from the workspace manifest. Tags and
/// the manifest move together in one release commit, so a commit merged into
/// the trunk reports the newest release that precedes it — which is exactly
/// the identity a "newer release than this pin" comparison needs.
pub fn version_at(mirror: &Path, rev: &str) -> Result<Version> {
    let manifest = git::git(mirror, &["show", &format!("{rev}:Cargo.toml")])?;
    let mut in_workspace = false;
    for line in manifest.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_workspace = line == "[workspace.package]";
            continue;
        }
        if !in_workspace {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        if key.trim() != "version" {
            continue;
        }
        let text = value.trim().trim_matches('"');
        return Version::parse(text).ok_or_else(|| {
            crate::support::error::Error::Request(format!(
                "{rev} declares workspace version {text:?}, which is not a release version"
            ))
        });
    }
    request_error(format!(
        "{rev} has no [workspace.package] version in Cargo.toml"
    ))
}

/// Whether a commit is merged into the trunk. A pin outside it is a commit
/// no release will ever contain, which is the pull-request head this gate
/// exists to refuse.
pub fn is_merged(mirror: &Path, rev: &str) -> Result<bool> {
    git::is_ancestor(mirror, rev, &format!("refs/heads/{TRUNK}"))
}

/// The release a pinned commit should be compared against, and the check
/// that it names a release that exists.
///
/// Reading the identity from the manifest assumes the trunk only learns a new
/// version through the release commit itself. If that ever stops holding, a
/// pin taken in the window would report an unreleased version, and every
/// later comparison would find nothing newer and silently freeze the pin. A
/// frozen pin looks exactly like a quiet upstream, so this refuses loudly
/// instead.
pub fn identity(mirror: &Path, rev: &str, releases: &[Release]) -> Result<Version> {
    let version = version_at(mirror, rev)?;
    if !releases.iter().any(|release| release.version == version) {
        return request_error(format!(
            "pinned commit {rev} declares version {version}, which has no release tag; \
             the pin cannot be compared against upstream releases"
        ));
    }
    Ok(version)
}

/// The release naming an exact version, for an explicit release request.
pub fn release_named(releases: &[Release], version: Version) -> Option<&Release> {
    releases.iter().find(|release| release.version == version)
}

/// How many commits `rev` carries that `reference` does not. Zero means the
/// reference already contains everything the revision did.
pub fn commits_not_in(mirror: &Path, rev: &str, reference: &str) -> Result<usize> {
    let output = git::git(
        mirror,
        &["rev-list", "--count", &format!("{reference}..{rev}")],
    )?;
    output.trim().parse().map_err(|_| {
        crate::support::error::Error::Request(format!(
            "git rev-list --count {reference}..{rev} returned {output:?}"
        ))
    })
}

/// The newest release strictly newer than `current`, if upstream has one.
pub fn newer_than(releases: &[Release], current: Version) -> Option<&Release> {
    releases.iter().rfind(|release| release.version > current)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prereleases_are_not_release_versions() {
        assert_eq!(
            Version::parse("v7.4.0"),
            Some(Version {
                major: 7,
                minor: 4,
                patch: 0
            })
        );
        assert_eq!(Version::parse("7.4.0"), Version::parse("v7.4.0"));
        for text in ["v7.3.0-rc.1", "v7.2.0-alpha.2", "v7.4", "v7.4.0.1", "main"] {
            assert_eq!(Version::parse(text), None, "{text} parsed as a release");
        }
    }

    #[test]
    fn versions_order_numerically_rather_than_lexically() {
        let (v9, v10) = (Version::parse("v7.9.0"), Version::parse("v7.10.0"));
        assert!(v9 < v10, "{v9:?} should precede {v10:?}");
    }

    #[test]
    fn newest_wins_and_an_equal_release_is_not_newer() {
        let releases: Vec<Release> = ["v7.2.0", "v7.2.1", "v7.3.0", "v7.4.0"]
            .into_iter()
            .map(|tag| Release {
                version: Version::parse(tag).unwrap(),
                tag: tag.to_string(),
                rev: tag.to_string(),
            })
            .collect();
        let current = Version::parse("v7.2.1").unwrap();
        assert_eq!(
            newer_than(&releases, current).map(|r| r.tag.as_str()),
            Some("v7.4.0")
        );
        let newest = Version::parse("v7.4.0").unwrap();
        assert!(newer_than(&releases, newest).is_none());
    }

    #[test]
    fn mirror_keys_are_stable_and_path_safe() {
        assert_eq!(
            mirror_key("https://github.com/wasmerio/wasmer.git"),
            "https-github-com-wasmerio-wasmer"
        );
        assert!(!mirror_key("https://example.com/a/../b").contains(".."));
    }
}
