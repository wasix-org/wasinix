//! Size-bounded logs that retain their opening context and newest output.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::support::atoms::Bytes;
use crate::support::error::{io, request_error, Result};
use crate::support::schema::Document;

const DEFAULT_MAX_BYTES: u64 = 64 * 1024 * 1024;
const HEAD_BYTES: u64 = 1024 * 1024;
const MARKER_RESERVE: u64 = 512;
const LIVE_MARKER: &[u8] =
    b"\n--- wasinix is retaining newer output in a rolling tail until this command ends ---\n";

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Retention {
    pub original_bytes: u64,
    pub retained_bytes: u64,
    pub omitted_bytes: u64,
    pub truncated: bool,
}

impl Document for Retention {
    const KIND: &'static str = "logRetention";
    const SCHEMA: u32 = 2;
}

#[derive(Debug, Default, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Summary {
    pub log_count: usize,
    pub truncated_count: usize,
    pub original_bytes: Bytes,
    pub retained_bytes: Bytes,
    pub omitted_bytes: Bytes,
}

impl Summary {
    pub fn is_empty(&self) -> bool {
        self.log_count == 0
    }
}

pub fn summarize(root: &Path) -> Result<Summary> {
    let mut summary = Summary::default();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound && dir == root => {
                return Ok(summary);
            }
            Err(error) => return Err(io(&dir, error)),
        };
        for entry in entries {
            let entry = entry.map_err(|error| io(&dir, error))?;
            let path = entry.path();
            let kind = entry.file_type().map_err(|error| io(&path, error))?;
            if kind.is_dir() {
                pending.push(path);
                continue;
            }
            if !kind.is_file()
                || !path
                    .file_name()
                    .is_some_and(|name| name.to_string_lossy().ends_with(".retention.json"))
            {
                continue;
            }
            let retention: Retention = crate::support::schema::read(&path)?;
            summary.log_count += 1;
            summary.truncated_count += usize::from(retention.truncated);
            summary.original_bytes.0 = summary
                .original_bytes
                .0
                .saturating_add(retention.original_bytes);
            summary.retained_bytes.0 = summary
                .retained_bytes
                .0
                .saturating_add(retention.retained_bytes);
            summary.omitted_bytes.0 = summary
                .omitted_bytes
                .0
                .saturating_add(retention.omitted_bytes);
        }
    }
    Ok(summary)
}

pub fn retention_path(path: &Path) -> PathBuf {
    path.with_file_name(format!(
        "{}.retention.json",
        path.file_name().unwrap_or_default().to_string_lossy()
    ))
}

pub struct BoundedLog {
    path: PathBuf,
    tail_path: PathBuf,
    head: Option<File>,
    tail: Option<File>,
    original_bytes: u64,
    head_bytes: u64,
    head_limit: u64,
    tail_bytes: u64,
    tail_position: u64,
    tail_limit: u64,
    live_marker_written: bool,
    finished: bool,
}

impl BoundedLog {
    pub fn create(path: &Path) -> Result<Self> {
        let max_bytes = crate::support::env::log_bytes()?
            .map(|bytes| bytes as u64)
            .unwrap_or(DEFAULT_MAX_BYTES);
        Self::with_limit(path, max_bytes)
    }

    fn create_followed(path: &Path) -> Result<Self> {
        let max_bytes = crate::support::env::log_bytes()?
            .map(|bytes| bytes as u64)
            .unwrap_or(DEFAULT_MAX_BYTES);
        let head_limit = (max_bytes.saturating_sub(MARKER_RESERVE)) / 2;
        Self::with_head_limit(path, max_bytes, head_limit)
    }

    fn with_limit(path: &Path, max_bytes: u64) -> Result<Self> {
        let head_limit = HEAD_BYTES.min((max_bytes.saturating_sub(MARKER_RESERVE)) / 4);
        Self::with_head_limit(path, max_bytes, head_limit)
    }

    fn with_head_limit(path: &Path, max_bytes: u64, head_limit: u64) -> Result<Self> {
        if max_bytes <= MARKER_RESERVE {
            return request_error(format!(
                "log retention needs more than {MARKER_RESERVE} bytes, got {max_bytes}"
            ));
        }
        if let Some(parent) = path.parent() {
            crate::support::fs::create_dir_all(parent)?;
        }
        let tail_limit = max_bytes - MARKER_RESERVE - head_limit;
        let tail_path = path.with_file_name(format!(
            ".{}.tail-{}",
            path.file_name().unwrap_or_default().to_string_lossy(),
            std::process::id()
        ));
        let tail = std::fs::OpenOptions::new()
            .create(true)
            .truncate(true)
            .read(true)
            .write(true)
            .open(&tail_path)
            .map_err(|error| io(&tail_path, error))?;
        Ok(Self {
            path: path.to_path_buf(),
            tail_path: tail_path.clone(),
            head: Some(File::create(path).map_err(|error| io(path, error))?),
            tail: Some(tail),
            original_bytes: 0,
            head_bytes: 0,
            head_limit,
            tail_bytes: 0,
            tail_position: 0,
            tail_limit,
            live_marker_written: false,
            finished: false,
        })
    }

    fn write_tail(&mut self, mut bytes: &[u8]) -> std::io::Result<()> {
        if !self.live_marker_written
            && self.tail_bytes.saturating_add(bytes.len() as u64) > self.tail_limit
        {
            self.head
                .as_mut()
                .expect("unfinished log has a head")
                .write_all(LIVE_MARKER)?;
            self.live_marker_written = true;
        }
        let tail = self.tail.as_mut().expect("unfinished log has a tail");
        if bytes.len() as u64 >= self.tail_limit {
            bytes = &bytes[bytes.len() - self.tail_limit as usize..];
            tail.seek(SeekFrom::Start(0))?;
            tail.write_all(bytes)?;
            self.tail_bytes = self.tail_limit;
            self.tail_position = 0;
            return Ok(());
        }

        let first = bytes
            .len()
            .min((self.tail_limit - self.tail_position) as usize);
        tail.seek(SeekFrom::Start(self.tail_position))?;
        tail.write_all(&bytes[..first])?;
        if first < bytes.len() {
            tail.seek(SeekFrom::Start(0))?;
            tail.write_all(&bytes[first..])?;
        }
        self.tail_position = (self.tail_position + bytes.len() as u64) % self.tail_limit;
        self.tail_bytes = self.tail_limit.min(self.tail_bytes + bytes.len() as u64);
        Ok(())
    }

    fn finalize(&mut self) -> Result<Retention> {
        if self.finished {
            return request_error(format!("{} was already finished", self.path.display()));
        }
        self.finished = true;
        let mut head = self.head.take().expect("unfinished log has a head");
        let mut tail = self.tail.take().expect("unfinished log has a tail");
        let omitted_bytes = self.original_bytes - self.head_bytes - self.tail_bytes;
        let truncated = omitted_bytes > 0;
        if truncated {
            writeln!(
                head,
                "\n--- wasinix omitted {omitted_bytes} log bytes ---\n"
            )
            .map_err(|error| io(&self.path, error))?;
        }
        if self.tail_bytes > 0 {
            let start = if self.tail_bytes == self.tail_limit {
                self.tail_position
            } else {
                0
            };
            tail.seek(SeekFrom::Start(start))
                .map_err(|error| io(&self.tail_path, error))?;
            {
                let mut part = (&mut tail).take(self.tail_bytes - start);
                std::io::copy(&mut part, &mut head).map_err(|error| io(&self.path, error))?;
            }
            if start > 0 {
                tail.seek(SeekFrom::Start(0))
                    .map_err(|error| io(&self.tail_path, error))?;
                let mut part = (&mut tail).take(start);
                std::io::copy(&mut part, &mut head).map_err(|error| io(&self.path, error))?;
            }
        }
        head.flush().map_err(|error| io(&self.path, error))?;
        drop(head);
        drop(tail);
        std::fs::remove_file(&self.tail_path).map_err(|error| io(&self.tail_path, error))?;

        let retention = Retention {
            original_bytes: self.original_bytes,
            retained_bytes: std::fs::metadata(&self.path)
                .map_err(|error| io(&self.path, error))?
                .len(),
            omitted_bytes,
            truncated,
        };
        crate::support::schema::write(&retention_path(&self.path), &retention)?;
        Ok(retention)
    }

    pub fn finish(mut self) -> Result<Retention> {
        self.finalize()
    }
}

#[derive(Clone)]
pub struct SharedLog(Arc<Mutex<BoundedLog>>);

impl SharedLog {
    pub fn create(path: &Path) -> Result<Self> {
        Ok(Self(Arc::new(Mutex::new(BoundedLog::create(path)?))))
    }

    pub fn create_followed(path: &Path) -> Result<Self> {
        Ok(Self(Arc::new(Mutex::new(BoundedLog::create_followed(
            path,
        )?))))
    }

    pub fn finish(self) -> Result<Retention> {
        let log = Arc::try_unwrap(self.0)
            .map_err(|_| {
                crate::support::error::Error::Failure(
                    "cannot finish a retained log while a writer is still active".into(),
                )
            })?
            .into_inner()
            .map_err(|_| {
                crate::support::error::Error::Failure(
                    "cannot finish a retained log whose writer panicked".into(),
                )
            })?;
        log.finish()
    }
}

impl Write for SharedLog {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0
            .lock()
            .map_err(|_| std::io::Error::other("retained log writer panicked"))?
            .write(bytes)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.0
            .lock()
            .map_err(|_| std::io::Error::other("retained log writer panicked"))?
            .flush()
    }
}

impl Write for BoundedLog {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.original_bytes = self.original_bytes.saturating_add(bytes.len() as u64);
        let head_remaining = (self.head_limit - self.head_bytes) as usize;
        let head_bytes = head_remaining.min(bytes.len());
        if head_bytes > 0 {
            self.head
                .as_mut()
                .expect("unfinished log has a head")
                .write_all(&bytes[..head_bytes])?;
            self.head_bytes += head_bytes as u64;
        }
        self.write_tail(&bytes[head_bytes..])?;
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.head
            .as_mut()
            .expect("unfinished log has a head")
            .flush()?;
        self.tail
            .as_mut()
            .expect("unfinished log has a tail")
            .flush()
    }
}

impl Drop for BoundedLog {
    fn drop(&mut self) {
        if !self.finished {
            if let Err(error) = self.finalize() {
                crate::support::ui::warning(format!(
                    "could not finish retained log {}: {error}",
                    self.path.display()
                ));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    #[test]
    fn keeps_head_and_rolling_tail_with_facts() {
        let scratch = crate::support::fs::Scratch::create("wasinix-log-test").unwrap();
        let path = scratch.path().join("build.log");
        let input: Vec<u8> = (0..4096).map(|index| (index % 251) as u8).collect();
        let mut log = super::BoundedLog::with_limit(&path, 2048).unwrap();
        for chunk in input.chunks(73) {
            log.write_all(chunk).unwrap();
        }
        let retention = log.finish().unwrap();

        let output = std::fs::read(&path).unwrap();
        assert_eq!(&output[..384], &input[..384]);
        assert_eq!(&output[output.len() - 1152..], &input[input.len() - 1152..]);
        assert!(output.len() <= 2048);
        assert_eq!(retention.original_bytes, 4096);
        assert_eq!(retention.retained_bytes, output.len() as u64);
        assert_eq!(retention.omitted_bytes, 2560);
        assert!(retention.truncated);
        let persisted: super::Retention =
            crate::support::schema::read(&super::retention_path(&path)).unwrap();
        assert_eq!(persisted.original_bytes, retention.original_bytes);
    }

    #[test]
    fn leaves_a_small_log_unchanged() {
        let scratch = crate::support::fs::Scratch::create("wasinix-log-small-test").unwrap();
        let path = scratch.path().join("build.log");
        let mut log = super::BoundedLog::with_limit(&path, 2048).unwrap();
        log.write_all(b"complete output\n").unwrap();
        let retention = log.finish().unwrap();

        assert_eq!(std::fs::read(&path).unwrap(), b"complete output\n");
        assert!(!retention.truncated);
        assert_eq!(retention.original_bytes, retention.retained_bytes);
    }

    #[test]
    fn a_followed_log_only_appends_while_it_is_live() {
        let scratch = crate::support::fs::Scratch::create("wasinix-log-follow-test").unwrap();
        let path = scratch.path().join("run.log");
        let input: Vec<u8> = (0..4096).map(|index| (index % 251) as u8).collect();
        let mut log = super::BoundedLog::with_head_limit(&path, 2048, 768).unwrap();
        log.write_all(&input[..1600]).unwrap();
        let live = std::fs::read(&path).unwrap();
        assert!(live.ends_with(super::LIVE_MARKER));

        log.write_all(&input[1600..]).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), live);
        let retention = log.finish().unwrap();
        let finished = std::fs::read(&path).unwrap();
        assert!(finished.starts_with(&live));
        assert_eq!(
            &finished[finished.len() - 768..],
            &input[input.len() - 768..]
        );
        assert!(retention.truncated);
        assert!(finished.len() <= 2048);
    }

    #[test]
    fn summaries_fold_every_retention_document_under_a_run() {
        let scratch = crate::support::fs::Scratch::create("wasinix-log-summary-test").unwrap();
        let first = scratch.path().join("cases/a/build.log");
        let second = scratch.path().join("run.log");
        let mut large = super::BoundedLog::with_limit(&first, 2048).unwrap();
        large.write_all(&vec![b'x'; 4096]).unwrap();
        let large = large.finish().unwrap();
        let mut small = super::BoundedLog::with_limit(&second, 2048).unwrap();
        small.write_all(b"small\n").unwrap();
        let small = small.finish().unwrap();

        let summary = super::summarize(scratch.path()).unwrap();
        assert_eq!(summary.log_count, 2);
        assert_eq!(summary.truncated_count, 1);
        assert_eq!(summary.original_bytes.0, 4102);
        assert_eq!(
            summary.retained_bytes.0,
            large.retained_bytes + small.retained_bytes
        );
        assert_eq!(summary.omitted_bytes.0, large.omitted_bytes);
    }
}
