//! Size-bounded logs that retain their opening context and newest output.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::support::error::{io, request_error, Result};
use crate::support::schema::Document;

const DEFAULT_MAX_BYTES: u64 = 64 * 1024 * 1024;
const HEAD_BYTES: u64 = 1024 * 1024;
const MARKER_RESERVE: u64 = 256;

#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Retention {
    pub original_bytes: u64,
    pub retained_bytes: u64,
    pub truncated: bool,
}

impl Document for Retention {
    const KIND: &'static str = "logRetention";
    const SCHEMA: u32 = 1;
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
    finished: bool,
}

impl BoundedLog {
    pub fn create(path: &Path) -> Result<Self> {
        let max_bytes = crate::support::env::log_bytes()?
            .map(|bytes| bytes as u64)
            .unwrap_or(DEFAULT_MAX_BYTES);
        Self::with_limit(path, max_bytes)
    }

    fn with_limit(path: &Path, max_bytes: u64) -> Result<Self> {
        if max_bytes <= MARKER_RESERVE + 1 {
            return request_error(format!(
                "log retention needs more than {MARKER_RESERVE} bytes, got {max_bytes}"
            ));
        }
        if let Some(parent) = path.parent() {
            crate::support::fs::create_dir_all(parent)?;
        }
        let head_limit = HEAD_BYTES.min((max_bytes - MARKER_RESERVE) / 4);
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
            finished: false,
        })
    }

    fn write_tail(&mut self, mut bytes: &[u8]) -> std::io::Result<()> {
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
        let truncated = self.original_bytes > self.head_bytes + self.tail_bytes;
        if truncated {
            let omitted = self.original_bytes - self.head_bytes - self.tail_bytes;
            writeln!(head, "\n--- wasinix omitted {omitted} log bytes ---\n")
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
            truncated,
        };
        crate::support::schema::write(&retention_path(&self.path), &retention)?;
        Ok(retention)
    }

    pub fn finish(mut self) -> Result<Retention> {
        self.finalize()
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
        let mut log = super::BoundedLog::with_limit(&path, 1024).unwrap();
        for chunk in input.chunks(73) {
            log.write_all(chunk).unwrap();
        }
        let retention = log.finish().unwrap();

        let output = std::fs::read(&path).unwrap();
        assert_eq!(&output[..192], &input[..192]);
        assert_eq!(&output[output.len() - 576..], &input[input.len() - 576..]);
        assert!(output.len() <= 1024);
        assert_eq!(retention.original_bytes, 4096);
        assert_eq!(retention.retained_bytes, output.len() as u64);
        assert!(retention.truncated);
        let persisted: super::Retention =
            crate::support::schema::read(&super::retention_path(&path)).unwrap();
        assert_eq!(persisted.original_bytes, retention.original_bytes);
    }

    #[test]
    fn leaves_a_small_log_unchanged() {
        let scratch = crate::support::fs::Scratch::create("wasinix-log-small-test").unwrap();
        let path = scratch.path().join("build.log");
        let mut log = super::BoundedLog::with_limit(&path, 1024).unwrap();
        log.write_all(b"complete output\n").unwrap();
        let retention = log.finish().unwrap();

        assert_eq!(std::fs::read(&path).unwrap(), b"complete output\n");
        assert!(!retention.truncated);
        assert_eq!(retention.original_bytes, retention.retained_bytes);
    }
}
