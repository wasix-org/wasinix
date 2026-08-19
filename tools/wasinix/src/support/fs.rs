//! Filesystem access that always names its path in errors, writes state files
//! atomically, and cleans up its scratch space.

use std::path::{Path, PathBuf};

use crate::support::error::{io, Result};

pub fn read_to_string(path: &Path) -> Result<String> {
    std::fs::read_to_string(path).map_err(|e| io(path, e))
}

pub fn write(path: &Path, contents: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| io(parent, e))?;
    }
    std::fs::write(path, contents).map_err(|e| io(path, e))
}

/// Write-then-rename, so concurrent readers see the old or the new document,
/// never a torn one. The temp name embeds the pid, so two writers never rename
/// each other's half-written file.
pub fn write_atomic(path: &Path, contents: &[u8]) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| io(parent, e))?;
    }
    let name = path
        .file_name()
        .map(|n| n.to_string_lossy().to_string())
        .unwrap_or_else(|| "file".to_string());
    let tmp = path.with_file_name(format!(".{name}.{}.tmp", std::process::id()));
    std::fs::write(&tmp, contents).map_err(|e| io(&tmp, e))?;
    std::fs::rename(&tmp, path).map_err(|e| io(path, e))
}

/// Append to a file, creating it when absent. The step summary is written by
/// several steps of one job, so each writes its own section rather than
/// replacing what came before.
pub fn append(path: &Path, contents: &[u8]) -> Result<()> {
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|error| io(path, error))?;
    file.write_all(contents).map_err(|error| io(path, error))
}

/// An absolute path, so a caller handing it to a tool rooted elsewhere
/// (`git -C`, a builder's cwd) names the same file the process meant.
pub fn absolute(path: &Path) -> Result<PathBuf> {
    std::path::absolute(path).map_err(|error| io(path, error))
}

pub fn create_dir_all(path: &Path) -> Result<()> {
    std::fs::create_dir_all(path).map_err(|e| io(path, e))
}

#[cfg(unix)]
pub fn set_mode(path: &Path, mode: u32) -> Result<()> {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).map_err(|e| io(path, e))
}

/// A private temp directory removed on drop. The name embeds pid and a
/// counter, and creation fails rather than adopting a leftover directory.
pub struct Scratch(PathBuf);

impl Scratch {
    pub fn create(prefix: &str) -> Result<Scratch> {
        let base = crate::support::env::temp_dir();
        for attempt in 0u32.. {
            let path = base.join(format!("{prefix}-{}-{attempt}", std::process::id()));
            match std::fs::create_dir(&path) {
                Ok(()) => return Ok(Scratch(path)),
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                Err(e) => return Err(io(&path, e)),
            }
        }
        unreachable!("u32 attempt space exhausted");
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        if let Err(e) = std::fs::remove_dir_all(&self.0) {
            crate::support::ui::warning(format!("could not remove {}: {e}", self.0.display()));
        }
    }
}

/// Recursive copy that fails on the first unreadable entry rather than
/// silently skipping it. `mode` is applied to every copied file, for store
/// sources whose read-only bits must not survive the copy.
pub fn copy_tree(from: &Path, to: &Path, mode: Option<u32>) -> Result<()> {
    create_dir_all(to)?;
    let entries = std::fs::read_dir(from).map_err(|e| io(from, e))?;
    for entry in entries {
        let entry = entry.map_err(|e| io(from, e))?;
        let source = entry.path();
        let target = to.join(entry.file_name());
        let kind = entry.file_type().map_err(|e| io(&source, e))?;
        if kind.is_dir() {
            copy_tree(&source, &target, mode)?;
        } else {
            std::fs::copy(&source, &target).map_err(|e| io(&source, e))?;
            if let Some(mode) = mode {
                set_mode(&target, mode)?;
            }
        }
    }
    Ok(())
}

/// One entry (file or directory) copied to `target`; the merge fetch moves
/// per-entry so it can skip names the destination owns.
pub fn copy_tree_entry(source: &Path, target: &Path) -> Result<()> {
    if source.is_dir() {
        copy_tree(source, target, None)
    } else {
        if let Some(parent) = target.parent() {
            create_dir_all(parent)?;
        }
        std::fs::copy(source, target).map_err(|e| io(source, e))?;
        Ok(())
    }
}

/// The last `limit` bytes of a file, without reading the whole file: run logs
/// reach hundreds of megabytes.
pub fn tail(path: &Path, limit: u64) -> Result<String> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = std::fs::File::open(path).map_err(|e| io(path, e))?;
    let len = file.metadata().map_err(|e| io(path, e))?.len();
    if len > limit {
        file.seek(SeekFrom::Start(len - limit)).map_err(|e| io(path, e))?;
    }
    let mut buffer = Vec::new();
    file.read_to_end(&mut buffer).map_err(|e| io(path, e))?;
    Ok(String::from_utf8_lossy(&buffer).into_owned())
}
