//! Materialize a case into a reproducible worktree. A case is a revision
//! plus a patch that overrides pins; preparing one writes that patch out with
//! its digest, and reproducing one applies the same patch to the same
//! revision and refuses if either moved.

use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::ci::types::{CaseRef, Override, OverrideKind, RevSource};
use crate::support::error::{io, request_error, Result};
use crate::support::git::{git, git_raw};
use crate::support::schema::Document;

pub const PATCH_FILE: &str = "materialization.patch";

fn digest(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}

/// The caller's uncommitted changes as a patch against HEAD. Untracked files
/// are not part of the change, exactly as `git diff` treats them.
pub fn working_patch(repo: &Path) -> Result<String> {
    git_raw(repo, &["diff", "--binary", "HEAD"])
}

fn apply_patch(worktree: &Path, patch: &str) -> Result<()> {
    if patch.is_empty() {
        return Ok(());
    }
    crate::support::git::git_stdin(
        worktree,
        &["apply", "--index", "--binary", "-"],
        patch.as_bytes(),
    )
}

/// Rewrite pins in the worktree, with this binary rather than the worktree's:
/// the worktree holds the revision under test, which must never run code
/// during materialization.
fn materialize_overrides(worktree: &Path, overrides: &[Override]) -> Result<()> {
    let mut sorted: Vec<&Override> = overrides.iter().collect();
    sorted.sort_by(|a, b| a.target.cmp(&b.target));
    for value in sorted {
        let source = match value.kind {
            OverrideKind::Release => value.value.clone(),
            OverrideKind::Revision => format!("rev:{}", value.value),
        };
        let exe = crate::support::env::current_exe()?;
        let mut cmd = Command::new(exe);
        cmd.arg("update")
            .arg(format!("{}@{source}", value.target))
            .current_dir(worktree);
        crate::support::tools::checked_output(&mut cmd, &format!("update {}", value.target))?;
    }
    Ok(())
}

/// A worktree at a revision, in its own private parent directory, removed
/// when the guard drops. Each guard owns its whole parent, so sibling
/// worktrees in one process cannot delete each other.
pub struct Worktree {
    repo: PathBuf,
    parent: PathBuf,
    path: PathBuf,
}

impl Worktree {
    pub fn add(repo: &Path, rev: &str) -> Result<Worktree> {
        let base = crate::support::env::temp_dir();
        let mut parent = PathBuf::new();
        for attempt in 0u32.. {
            // The path seeds nix's fetcher cache: the worktree evaluates as
            // a git+file flake, and one url must never carry two contents,
            // so the parent is unique per creation.
            let candidate = base.join(format!(
                "wasinix-worktree-{}-{}-{attempt}",
                std::process::id(),
                crate::support::time::unix_secs()
            ));
            match std::fs::create_dir(&candidate) {
                Ok(()) => {
                    parent = candidate;
                    break;
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(error) => return Err(io(&candidate, error)),
            }
        }
        let path = parent.join("worktree");
        git(
            repo,
            &["worktree", "add", "--detach", &path.to_string_lossy(), rev],
        )?;
        Ok(Worktree {
            repo: repo.to_path_buf(),
            parent,
            path,
        })
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for Worktree {
    fn drop(&mut self) {
        if let Err(error) = git(
            &self.repo,
            &[
                "worktree",
                "remove",
                "--force",
                &self.path.to_string_lossy(),
            ],
        ) {
            crate::support::ui::warning(format!(
                "could not remove worktree {}: {error}",
                self.path.display()
            ));
        }
        if let Err(error) = std::fs::remove_dir_all(&self.parent) {
            if error.kind() != std::io::ErrorKind::NotFound {
                crate::support::ui::warning(format!(
                    "could not remove {}: {error}",
                    self.parent.display()
                ));
            }
        }
    }
}

/// How a prepared case is reproduced: which revision, which patch, and the
/// digest both sides must agree on.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Materialization {
    pub request_id: String,
    pub source_rev: crate::support::atoms::Rev,
    pub patch: String,
    pub patch_hash: String,
}

impl Document for Materialization {
    const KIND: &'static str = "materialization";
    const SCHEMA: u32 = 1;
}

/// Prepare a case: apply the caller's changes and its overrides, then record
/// the resulting patch so any machine can reproduce the same tree.
pub fn write_materialization(
    repo: &Path,
    case: CaseRef<'_, RevSource>,
    case_value: &serde_json::Value,
    out_dir: &Path,
) -> Result<Materialization> {
    crate::support::fs::create_dir_all(out_dir)?;
    let source = case.source();
    let initial = if source.working_tree {
        working_patch(repo)?
    } else {
        String::new()
    };

    let worktree = Worktree::add(repo, source.rev.full())?;
    apply_patch(worktree.path(), &initial)?;
    materialize_overrides(worktree.path(), case.overrides())?;
    let patch = git_raw(worktree.path(), &["diff", "--binary", source.rev.full()])?;
    crate::support::fs::write(&out_dir.join(PATCH_FILE), patch.as_bytes())?;

    let patch_hash = digest(&patch);
    let mut materialized = case_value.clone();
    materialized["source"]["patch"] = serde_json::Value::String(patch_hash.clone());
    let request_id = crate::ci::normalize::request_id(&materialized);
    crate::support::json::write(&out_dir.join("request.json"), &materialized)?;

    let manifest = Materialization {
        request_id,
        source_rev: source.rev.clone(),
        patch: PATCH_FILE.to_string(),
        patch_hash,
    };
    crate::support::schema::write(&out_dir.join("materialization.json"), &manifest)?;
    Ok(manifest)
}

/// A worktree at the case's revision with its materialization patch applied,
/// removed when the guard drops.
pub struct Reproduced {
    worktree: Worktree,
}

impl Reproduced {
    pub fn path(&self) -> &Path {
        self.worktree.path()
    }
}

pub fn reproduced_worktree(
    repo: &Path,
    source: &RevSource,
    patch_path: &Path,
) -> Result<Reproduced> {
    let worktree = Worktree::add(repo, source.rev.full())?;
    match &source.patch {
        Some(expected) => {
            let patch = crate::support::fs::read_to_string(patch_path)?;
            if &digest(&patch) != expected {
                return request_error(format!(
                    "{} does not match the request's patch hash",
                    patch_path.display()
                ));
            }
            apply_patch(worktree.path(), &patch)?;
        }
        None => {
            if patch_path.exists() {
                let patch = crate::support::fs::read_to_string(patch_path)?;
                if !patch.is_empty() {
                    return request_error(format!(
                        "{} exists but the request records no patch",
                        patch_path.display()
                    ));
                }
            }
        }
    }
    Ok(Reproduced { worktree })
}
