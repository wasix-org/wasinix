//! The run's event stream: every progress view (terminal ladder, milestone
//! lines, `run watch`, remote tailing) renders the same append-only
//! `events.jsonl`, and the snapshot is derived from it, never maintained
//! beside it.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::ci::facts::Diagnostic;
use crate::support::atoms::{DurationSecs, JobAddr, JobStatus, RunState, TaskStatus};
use crate::support::error::{Error, Result, io};
use crate::support::schema::Document;

pub const SCHEMA: u32 = 1;
pub const FILE: &str = "events.jsonl";
pub const SNAPSHOT: &str = "snapshot.json";

/// One line of `events.jsonl`. Each line carries the schema, so a stream can
/// be read across a host boundary without out-of-band context.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", rename_all = "camelCase")]
pub enum Event {
    #[serde(rename_all = "camelCase")]
    RunStarted { at: u64, pid: u32 },
    #[serde(rename_all = "camelCase")]
    PhaseStarted {
        at: u64,
        task_id: String,
        label: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        jobs: Option<usize>,
    },
    #[serde(rename_all = "camelCase")]
    PhaseFinished {
        at: u64,
        task_id: String,
        status: TaskStatus,
        headline: String,
    },
    #[serde(rename_all = "camelCase")]
    JobStarted { at: u64, job: JobAddr },
    #[serde(rename_all = "camelCase")]
    JobFinished {
        at: u64,
        job: JobAddr,
        status: JobStatus,
        #[serde(default)]
        cached: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        duration_seconds: Option<DurationSecs>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Warning { at: u64, message: String },
    #[serde(rename_all = "camelCase")]
    Output { at: u64, line: String },
    #[serde(rename_all = "camelCase")]
    Diagnostic { at: u64, diagnostic: Diagnostic },
    #[serde(rename_all = "camelCase")]
    Heartbeat {
        at: u64,
        /// What the run is doing when no job is in flight, or nothing.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    RunFinished {
        at: u64,
        state: RunState,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        exit_code: Option<u8>,
    },
}

impl Event {
    pub fn at(&self) -> u64 {
        match self {
            Event::RunStarted { at, .. }
            | Event::PhaseStarted { at, .. }
            | Event::PhaseFinished { at, .. }
            | Event::JobStarted { at, .. }
            | Event::JobFinished { at, .. }
            | Event::Warning { at, .. }
            | Event::Output { at, .. }
            | Event::Diagnostic { at, .. }
            | Event::Heartbeat { at, .. }
            | Event::RunFinished { at, .. } => *at,
        }
    }
}

/// A live view of an event stream. Time is an input beside events: a quiet
/// process still has progress to render, and every transport supplies its own
/// polling cadence.
pub trait ProgressSink {
    fn event(&mut self, event: &Event);
    fn tick(&mut self, at: u64);

    fn observe(&mut self, events: &[Event]) {
        for event in events {
            self.event(event);
        }
        self.tick(crate::support::time::unix_secs());
    }
}

#[derive(Serialize, Deserialize)]
struct Line {
    schema: u32,
    #[serde(flatten)]
    event: Event,
}

/// Append one event. A line is one `write(2)` of well under a pipe buffer, so
/// concurrent readers never see a torn line except the file's very tail.
pub fn append(run_dir: &Path, event: &Event) -> Result<()> {
    let path = run_dir.join(FILE);
    let mut line = serde_json::to_string(&Line {
        schema: SCHEMA,
        event: event.clone(),
    })
    .map_err(|source| Error::Json {
        path: path.clone(),
        source,
    })?;
    line.push('\n');
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| io(&path, e))?;
    file.write_all(line.as_bytes()).map_err(|e| io(&path, e))
}

/// Decode a chunk of already-encoded event lines (a mirrored remote
/// stream): complete lines become events, and the torn tail is returned as
/// the carry for the next chunk. Appends only the complete lines to the
/// run's stream, so a concurrent local writer never sees a torn middle.
pub fn ingest_chunk(run_dir: &Path, carry: &mut Vec<u8>, chunk: &[u8]) -> Result<Vec<Event>> {
    use std::io::Write;
    carry.extend_from_slice(chunk);
    let Some(index) = carry.iter().rposition(|byte| *byte == b'\n') else {
        return Ok(Vec::new());
    };
    let complete: Vec<u8> = carry.drain(..=index).collect();
    let path = run_dir.join(FILE);
    let text = String::from_utf8_lossy(&complete).into_owned();
    let mut events = Vec::new();
    for line in text.split_inclusive('\n') {
        let parsed: Line = serde_json::from_str(line).map_err(|source| Error::Json {
            path: path.clone(),
            source,
        })?;
        events.push(parsed.event);
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .map_err(|e| io(&path, e))?;
    file.write_all(&complete).map_err(|e| io(&path, e))?;
    Ok(events)
}

/// Read a stream from an offset, returning the events and the new offset. A
/// torn final line is an in-flight append and is left for the next read; a
/// torn line anywhere else is corruption and fails loudly.
pub fn read_from(path: &Path, offset: u64) -> Result<(Vec<Event>, u64)> {
    use std::io::{Read, Seek, SeekFrom};
    let mut file = match std::fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((Vec::new(), offset));
        }
        Err(error) => return Err(io(path, error)),
    };
    file.seek(SeekFrom::Start(offset))
        .map_err(|e| io(path, e))?;
    // Read bytes, not a string: a remote observer mirrors `tail -c` chunks
    // that can end mid-multibyte-sequence, and a torn tail is an in-flight
    // append, never corruption. Only complete lines are decoded and consumed.
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).map_err(|e| io(path, e))?;
    let complete = match bytes.iter().rposition(|byte| *byte == b'\n') {
        Some(index) => &bytes[..=index],
        None => return Ok((Vec::new(), offset)),
    };
    let text = String::from_utf8_lossy(complete);
    let mut events = Vec::new();
    for line in text.split_inclusive('\n') {
        if !line.ends_with('\n') {
            break;
        }
        let parsed: Line = serde_json::from_str(line).map_err(|source| Error::Json {
            path: path.to_path_buf(),
            source,
        })?;
        if parsed.schema != SCHEMA {
            return Err(Error::Failure(format!(
                "{}: event schema {} is not the supported {SCHEMA}",
                path.display(),
                parsed.schema
            )));
        }
        events.push(parsed.event);
    }
    // Every complete line parsed, so the byte-accurate advance is the whole
    // complete prefix; this stays correct even if a line held bytes the lossy
    // decode changed the length of.
    Ok((events, offset + complete.len() as u64))
}

pub fn read_all(run_dir: &Path) -> Result<Vec<Event>> {
    Ok(read_from(&run_dir.join(FILE), 0)?.0)
}

/// The one tail loop every live progress view runs on: each batch of fresh
/// events (possibly empty) goes to `sink`, until the stream carries
/// RunFinished or `drained` reports the run over while nothing new arrived.
/// A stream that does not exist yet reads as empty batches.
pub fn tail(
    run_dir: &Path,
    poll: std::time::Duration,
    mut sink: impl FnMut(&[Event]) -> Result<()>,
    mut drained: impl FnMut() -> Result<bool>,
) -> Result<()> {
    let path = run_dir.join(FILE);
    let mut offset = 0;
    loop {
        let (fresh, next) = read_from(&path, offset)?;
        offset = next;
        sink(&fresh)?;
        if fresh
            .iter()
            .any(|event| matches!(event, Event::RunFinished { .. }))
        {
            return Ok(());
        }
        if fresh.is_empty() && drained()? {
            return Ok(());
        }
        std::thread::sleep(poll);
    }
}

/// One phase as the snapshot sees it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhaseSnapshot {
    pub task_id: String,
    pub label: String,
    pub status: TaskStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub headline: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub jobs: Option<usize>,
}

/// The derived view a poller reads: totals, the phase ladder, and the recent
/// tail, never the full per-job map.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub state: RunState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_code: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub started_at: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_event_at: Option<u64>,
    pub completed_jobs: usize,
    pub cached_jobs: usize,
    pub failed_jobs: usize,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub phases: Vec<PhaseSnapshot>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub recent_failures: Vec<JobAddr>,
    /// Jobs started and not yet finished: where the build is right now.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub building: Vec<JobAddr>,
}

impl Document for Snapshot {
    const KIND: &'static str = "snapshot";
    const SCHEMA: u32 = 1;
}

#[derive(Default)]
struct SnapshotReducer {
    snapshot: Snapshot,
    phases: BTreeMap<String, usize>,
}

impl SnapshotReducer {
    fn apply(&mut self, event: &Event) {
        self.snapshot.last_event_at = Some(event.at());
        match event {
            Event::RunStarted { at, .. } => {
                self.snapshot.state = RunState::Running;
                self.snapshot.started_at = Some(*at);
            }
            Event::PhaseStarted {
                at,
                task_id,
                label,
                jobs,
                ..
            } => {
                let index = self.snapshot.phases.len();
                self.phases.insert(task_id.clone(), index);
                self.snapshot.phases.push(PhaseSnapshot {
                    task_id: task_id.clone(),
                    label: label.clone(),
                    status: TaskStatus::Pending,
                    started_at: Some(*at),
                    headline: None,
                    jobs: *jobs,
                });
            }
            Event::PhaseFinished {
                task_id,
                status,
                headline,
                ..
            } => {
                // A finish for a phase that never started (a recovery path
                // that failed before its PhaseStarted) still appears, rather
                // than vanishing from the ladder.
                let index = *self.phases.entry(task_id.clone()).or_insert_with(|| {
                    let index = self.snapshot.phases.len();
                    self.snapshot.phases.push(PhaseSnapshot {
                        task_id: task_id.clone(),
                        label: task_id.clone(),
                        status: TaskStatus::Pending,
                        started_at: Some(event.at()),
                        headline: None,
                        jobs: None,
                    });
                    index
                });
                self.snapshot.phases[index].status = *status;
                self.snapshot.phases[index].headline = Some(headline.clone());
            }
            Event::JobStarted { job, .. } => {
                if !self.snapshot.building.contains(job) {
                    self.snapshot.building.push(job.clone());
                    // Bounded in case a finish event is ever lost; the live
                    // set is limited by max-jobs anyway.
                    if self.snapshot.building.len() > 64 {
                        self.snapshot.building.remove(0);
                    }
                }
            }
            Event::JobFinished {
                job,
                status,
                cached,
                ..
            } => {
                self.snapshot.building.retain(|started| started != job);
                self.snapshot.completed_jobs += 1;
                if *cached {
                    self.snapshot.cached_jobs += 1;
                }
                if *status == JobStatus::Failure {
                    self.snapshot.failed_jobs += 1;
                    self.snapshot.recent_failures.push(job.clone());
                    if self.snapshot.recent_failures.len() > 20 {
                        self.snapshot.recent_failures.remove(0);
                    }
                }
            }
            Event::Warning { .. }
            | Event::Output { .. }
            | Event::Diagnostic { .. }
            | Event::Heartbeat { .. } => {}
            Event::RunFinished {
                state, exit_code, ..
            } => {
                self.snapshot.state = *state;
                self.snapshot.exit_code = *exit_code;
            }
        }
    }

    fn from_events(events: &[Event]) -> SnapshotReducer {
        let mut reducer = SnapshotReducer::default();
        for event in events {
            reducer.apply(event);
        }
        reducer
    }
}

pub fn fold_snapshot(events: &[Event]) -> Snapshot {
    SnapshotReducer::from_events(events).snapshot
}

/// Appends events and keeps the derived snapshot fresh: on every phase
/// boundary and failure immediately, on job completions at most once a
/// second, so a 5000-job build does not write 5000 snapshots.
pub struct Tracker {
    run_dir: PathBuf,
    reducer: SnapshotReducer,
    last_write: Option<Instant>,
}

impl Tracker {
    pub fn new(run_dir: &Path) -> Result<Tracker> {
        let events = read_all(run_dir)?;
        Ok(Tracker {
            run_dir: run_dir.to_path_buf(),
            reducer: SnapshotReducer::from_events(&events),
            last_write: None,
        })
    }

    pub fn record(&mut self, event: Event) -> Result<()> {
        append(&self.run_dir, &event)?;
        let urgent = !matches!(
            event,
            Event::JobFinished {
                status: JobStatus::Success,
                ..
            } | Event::Heartbeat { .. }
        );
        self.reducer.apply(&event);
        if urgent
            || self
                .last_write
                .is_none_or(|last| last.elapsed() >= std::time::Duration::from_secs(1))
        {
            self.write_snapshot()?;
        }
        Ok(())
    }

    pub fn phase<T>(
        &mut self,
        task_id: impl Into<String>,
        label: impl Into<String>,
        work: impl FnOnce() -> Result<T>,
        headline: impl FnOnce(&T) -> String,
    ) -> Result<T> {
        let task_id = task_id.into();
        self.record(Event::PhaseStarted {
            at: crate::support::time::unix_secs(),
            task_id: task_id.clone(),
            label: label.into(),
            jobs: None,
        })?;
        match work() {
            Ok(value) => {
                self.record(Event::PhaseFinished {
                    at: crate::support::time::unix_secs(),
                    task_id,
                    status: TaskStatus::Success,
                    headline: headline(&value),
                })?;
                Ok(value)
            }
            Err(error) => {
                let finished = self.record(Event::PhaseFinished {
                    at: crate::support::time::unix_secs(),
                    task_id,
                    status: TaskStatus::Failure,
                    headline: crate::support::error::brief(&error, 200),
                });
                crate::support::error::finalize(Err(error), finished, "could not finish phase")
            }
        }
    }

    pub fn snapshot(&self) -> Snapshot {
        self.reducer.snapshot.clone()
    }

    pub fn write_snapshot(&mut self) -> Result<()> {
        crate::support::schema::write(&self.run_dir.join(SNAPSHOT), &self.reducer.snapshot)?;
        self.last_write = Some(Instant::now());
        Ok(())
    }
}

pub fn read_snapshot(run_dir: &Path) -> Result<Snapshot> {
    crate::support::schema::read(&run_dir.join(SNAPSHOT))
}
