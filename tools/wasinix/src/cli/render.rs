//! Terminal renderers over the run's event stream. Every progress view
//! (in-process builds, `run watch`, joining mid-run) replays the same
//! events.jsonl, so they cannot tell different stories.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use indicatif::{ProgressBar, ProgressStyle};

use crate::ci::events::{self, Event};
use crate::support::atoms::{JobStatus, TaskStatus};
use crate::support::error::Result;
use crate::support::format;
use crate::support::terminal::interactive;

/// How many failure-detail lines one job may print.
const FAILURE_DETAIL_LINES: usize = 6;
const MILESTONE_EVERY: usize = 50;

pub struct LineRenderer {
    started_at: Option<u64>,
    bar: Option<ProgressBar>,
    total_jobs: usize,
    completed: usize,
    failed: usize,
    building: std::collections::BTreeSet<String>,
}

fn glyph(status: TaskStatus) -> &'static str {
    match status {
        TaskStatus::Success => "✓",
        TaskStatus::Failure | TaskStatus::Cancelled => "✗",
        TaskStatus::Neutral => "⚠",
        TaskStatus::Skipped | TaskStatus::Deferred => "·",
        TaskStatus::Pending => "·",
    }
}

impl LineRenderer {
    pub fn new() -> LineRenderer {
        LineRenderer::with_spinner(interactive())
    }

    /// The spinner decision made explicit: a spinner absorbs the milestone
    /// lines, and a nix sandbox runs builders on a pseudoterminal, so a test
    /// pinning the narration must choose line mode rather than detect it.
    pub(crate) fn with_spinner(spinner: bool) -> LineRenderer {
        let bar = spinner.then(|| {
            let bar = ProgressBar::new_spinner().with_style(
                ProgressStyle::with_template("{spinner} {msg}")
                    .expect("the template is static"),
            );
            bar.enable_steady_tick(Duration::from_millis(120));
            bar
        });
        LineRenderer {
            started_at: None,
            bar,
            total_jobs: 0,
            completed: 0,
            failed: 0,
            building: std::collections::BTreeSet::new(),
        }
    }

    fn stamp(&self, at: u64) -> String {
        let elapsed = at.saturating_sub(self.started_at.unwrap_or(at));
        format!("[+{}]", format::duration(elapsed as f64))
    }

    fn line(&self, text: String) {
        match &self.bar {
            Some(bar) => bar.println(text),
            None => eprintln!("{text}"),
        }
    }

    fn counts(&self) -> String {
        let mut parts = Vec::new();
        if self.total_jobs > 0 {
            parts.push(format!("{}/{} jobs", self.completed, self.total_jobs));
        } else if self.completed > 0 {
            parts.push(format!("{} jobs", self.completed));
        }
        if self.failed > 0 {
            parts.push(format!("{} failed", self.failed));
        }
        crate::support::ui::counts(&parts)
    }

    /// [`counts`](Self::counts) plus the builds in flight, for the lines
    /// describing a run still going.
    fn progress(&self) -> String {
        let counts = self.counts();
        if self.building.is_empty() {
            return counts;
        }
        let names: Vec<&str> = self.building.iter().map(String::as_str).collect();
        let building = format!("building {}", format::some(&names, 3));
        if counts.is_empty() {
            building
        } else {
            crate::support::ui::counts(&[counts, building])
        }
    }

    /// The lines one event adds, so a test can replay a recorded stream and
    /// pin the narration without a terminal.
    pub fn lines_for(&mut self, event: &Event) -> Vec<String> {
        if self.started_at.is_none() {
            self.started_at = Some(event.at());
        }
        match event {
            Event::RunStarted { .. } => Vec::new(),
            // Five-minute liveness for otherwise quiet stretches: the union
            // build's evaluation emits no job events, and a long compile can
            // go just as silent.
            Event::Heartbeat { at } => {
                let progress = self.progress();
                if self.bar.is_none() && !progress.is_empty() {
                    vec![format!("{} {}", self.stamp(*at), progress)]
                } else {
                    Vec::new()
                }
            }
            // Starts feed the in-flight set the milestone lines and the bar
            // show; a line per start would drown the narration.
            Event::JobStarted { job, .. } => {
                self.building.insert(job.to_string());
                Vec::new()
            }
            Event::PhaseStarted { at, label, jobs, .. } => {
                self.total_jobs += jobs.unwrap_or(0);
                let size = jobs
                    .map(|jobs| format!(" · {jobs} jobs"))
                    .unwrap_or_default();
                vec![format!("{} {label}{size}", self.stamp(*at))]
            }
            Event::PhaseFinished {
                at,
                status,
                headline,
                task_id,
            } => {
                vec![format!(
                    "{} {} {task_id} · {headline}",
                    self.stamp(*at),
                    glyph(*status)
                )]
            }
            Event::JobFinished {
                at,
                job,
                status,
                error,
                ..
            } => {
                self.completed += 1;
                self.building.remove(job.as_str());
                if *status == JobStatus::Failure {
                    self.failed += 1;
                    let mut lines = vec![format!("{} ✗ {job}", self.stamp(*at))];
                    if let Some(error) = error {
                        lines.extend(
                            error
                                .lines()
                                .take(FAILURE_DETAIL_LINES)
                                .map(|line| format!("  │ {line}")),
                        );
                    }
                    lines
                } else if self.completed.is_multiple_of(MILESTONE_EVERY) && self.bar.is_none() {
                    vec![format!("{} {}", self.stamp(*at), self.progress())]
                } else {
                    Vec::new()
                }
            }
            Event::Warning { at, message } => {
                vec![format!("{} warning: {message}", self.stamp(*at))]
            }
            Event::RunFinished { at, state, .. } => {
                let mut parts = vec![state.to_string()];
                let counts = self.counts();
                if !counts.is_empty() {
                    parts.push(counts);
                }
                vec![format!(
                    "{} {}",
                    self.stamp(*at),
                    crate::support::ui::counts(&parts)
                )]
            }
        }
    }

    pub fn event(&mut self, event: &Event) {
        for line in self.lines_for(event) {
            self.line(line);
        }
        if let Some(bar) = &self.bar {
            bar.set_message(self.progress());
        }
    }

    pub fn finish(self) {
        if let Some(bar) = self.bar {
            bar.finish_and_clear();
        }
    }
}

/// Follow a run directory's stream until the run finishes (or `stop` is set
/// and the stream is drained), rendering as it goes.
pub fn follow(run_dir: &Path, stop: &AtomicBool) -> Result<()> {
    let mut renderer = LineRenderer::new();
    events::tail(
        run_dir,
        Duration::from_millis(300),
        |fresh| {
            for event in fresh {
                renderer.event(event);
            }
            Ok(())
        },
        || Ok(stop.load(Ordering::Relaxed)),
    )?;
    renderer.finish();
    Ok(())
}

/// A line renderer replaying the stream is the whole watch command.
pub fn watch(run_dir: &Path) -> Result<()> {
    let mut renderer = LineRenderer::new();
    events::tail(
        run_dir,
        Duration::from_millis(500),
        |fresh| {
            for event in fresh {
                renderer.event(event);
            }
            Ok(())
        },
        // A lost run never writes RunFinished; the observed record says so.
        || Ok(crate::runs::observed(run_dir)?.state.is_final()),
    )?;
    renderer.finish();
    Ok(())
}
