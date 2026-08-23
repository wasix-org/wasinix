//! Pinning and explicit retention policies for the durable run registry.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::runs::{PIN_FILE, RUN_FILE, Run, registry};
use crate::support::error::{Error, Result, io};
use crate::support::schema::{self, Document};
use crate::support::time::unix_secs;

#[derive(Clone, Copy)]
pub(crate) struct GcPolicy {
    pub(crate) max_age: Option<Duration>,
    pub(crate) max_count: Option<usize>,
    pub(crate) max_bytes: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CollectedRun {
    pub(crate) run_id: String,
    pub(crate) bytes: crate::support::atoms::Bytes,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct GcReport {
    pub(crate) dry_run: bool,
    pub(crate) collected: Vec<CollectedRun>,
    pub(crate) reclaimed_bytes: crate::support::atoms::Bytes,
    pub(crate) retained_runs: usize,
    pub(crate) retained_bytes: crate::support::atoms::Bytes,
    pub(crate) protected_active: usize,
    pub(crate) protected_pinned: usize,
}

impl Document for GcReport {
    const KIND: &'static str = "runGc";
    const SCHEMA: u32 = 1;
}

struct StoredRun {
    path: PathBuf,
    run: Run,
    bytes: u64,
    pinned: bool,
}

#[cfg(unix)]
struct RegistryLock {
    _file: std::fs::File,
}

#[cfg(unix)]
fn lock_registry(root: &Path) -> Result<RegistryLock> {
    use std::os::fd::AsRawFd;

    crate::support::fs::create_dir_all(root)?;
    let path = root.join(".lock");
    let file = std::fs::OpenOptions::new()
        .create(true)
        .read(true)
        .write(true)
        .open(&path)
        .map_err(|error| io(&path, error))?;
    // SAFETY: flock only reads the file descriptor and operation. The file
    // stays owned by RegistryLock for the full critical section.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(io(&path, std::io::Error::last_os_error()));
    }
    Ok(RegistryLock { _file: file })
}

#[cfg(not(unix))]
struct RegistryLock;

#[cfg(not(unix))]
fn lock_registry(root: &Path) -> Result<RegistryLock> {
    crate::support::fs::create_dir_all(root)?;
    Ok(RegistryLock)
}

fn inventory(root: &Path) -> Result<Vec<StoredRun>> {
    let entries = match std::fs::read_dir(root) {
        Ok(entries) => entries,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(io(root, error)),
    };
    let mut runs = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|error| io(root, error))?;
        let path = entry.path();
        if !entry
            .file_type()
            .map_err(|error| io(&path, error))?
            .is_dir()
        {
            continue;
        }
        let run_file = path.join(RUN_FILE);
        if !run_file
            .try_exists()
            .map_err(|error| io(&run_file, error))?
        {
            continue;
        }
        let run: Run = schema::read(&run_file)?;
        let directory_id = path
            .file_name()
            .and_then(|name| name.to_str())
            .ok_or_else(|| Error::Failure(format!("{} is not a unicode run id", path.display())))?;
        if run.run_id != directory_id {
            return Err(Error::Failure(format!(
                "{} records run id {:?}",
                path.display(),
                run.run_id
            )));
        }
        runs.push(StoredRun {
            run,
            bytes: crate::support::fs::tree_bytes(&path)?,
            pinned: path
                .join(PIN_FILE)
                .try_exists()
                .map_err(|error| io(path.join(PIN_FILE), error))?,
            path,
        });
    }
    runs.sort_by_key(|stored| std::cmp::Reverse(stored.run.started_at));
    Ok(runs)
}

pub(crate) fn set_pinned(run_id: &str, pinned: bool) -> Result<()> {
    let root = registry()?;
    let _lock = lock_registry(&root)?;
    let run_dir = crate::runs::dir_of(run_id)?;
    let marker = run_dir.join(PIN_FILE);
    if pinned {
        crate::support::fs::write(&marker, b"")
    } else {
        match std::fs::remove_file(&marker) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                Err(Error::Request(format!("run {run_id} is not pinned")))
            }
            Err(error) => Err(io(&marker, error)),
        }
    }
}

pub(crate) fn is_pinned(run_dir: &Path) -> Result<bool> {
    run_dir
        .join(PIN_FILE)
        .try_exists()
        .map_err(|error| io(run_dir.join(PIN_FILE), error))
}

pub(crate) fn gc(policy: GcPolicy, dry_run: bool) -> Result<GcReport> {
    let root = registry()?;
    let _lock = lock_registry(&root)?;
    gc_under(&root, policy, dry_run, unix_secs())
}

pub(crate) fn gc_under(root: &Path, policy: GcPolicy, dry_run: bool, now: u64) -> Result<GcReport> {
    if policy.max_age.is_none() && policy.max_count.is_none() && policy.max_bytes.is_none() {
        return Err(Error::Request(
            "run gc needs --max-age-days, --max-count, or --max-bytes".into(),
        ));
    }
    let runs = inventory(root)?;
    let total_bytes = runs.iter().try_fold(0u64, |total, run| {
        total
            .checked_add(run.bytes)
            .ok_or_else(|| Error::Failure("run registry byte count overflowed u64".into()))
    })?;
    let mut selected = vec![false; runs.len()];
    for (index, stored) in runs.iter().enumerate() {
        if !stored.run.state.is_final() || stored.pinned {
            continue;
        }
        let too_old = policy.max_age.is_some_and(|age| {
            now.saturating_sub(stored.run.finished_at.unwrap_or(stored.run.started_at))
                >= age.as_secs()
        });
        let too_many = policy.max_count.is_some_and(|count| index >= count);
        selected[index] = too_old || too_many;
    }
    let mut retained_bytes = runs
        .iter()
        .zip(&selected)
        .filter(|(_, selected)| !**selected)
        .map(|(run, _)| run.bytes)
        .sum::<u64>();
    if let Some(max_bytes) = policy.max_bytes {
        for (index, stored) in runs.iter().enumerate().rev() {
            if retained_bytes <= max_bytes {
                break;
            }
            if selected[index] || !stored.run.state.is_final() || stored.pinned {
                continue;
            }
            selected[index] = true;
            retained_bytes = retained_bytes.saturating_sub(stored.bytes);
        }
    }

    let mut collected = Vec::new();
    for (index, stored) in runs.iter().enumerate().rev() {
        if !selected[index] {
            continue;
        }
        if !dry_run {
            let current: Run = schema::read(&stored.path.join(RUN_FILE))?;
            if !current.state.is_final() || is_pinned(&stored.path)? {
                retained_bytes = retained_bytes.saturating_add(stored.bytes);
                continue;
            }
            crate::support::fs::remove_dir_all(&stored.path)?;
        }
        collected.push(CollectedRun {
            run_id: stored.run.run_id.clone(),
            bytes: crate::support::atoms::Bytes(stored.bytes),
        });
    }
    let reclaimed_bytes = total_bytes.saturating_sub(retained_bytes);
    Ok(GcReport {
        dry_run,
        retained_runs: runs.len().saturating_sub(collected.len()),
        retained_bytes: crate::support::atoms::Bytes(retained_bytes),
        protected_active: runs.iter().filter(|run| !run.run.state.is_final()).count(),
        protected_pinned: runs.iter().filter(|run| run.pinned).count(),
        collected,
        reclaimed_bytes: crate::support::atoms::Bytes(reclaimed_bytes),
    })
}
