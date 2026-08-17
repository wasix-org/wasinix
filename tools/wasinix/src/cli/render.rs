//! Terminal renderers over the run's event stream. Every progress view
//! (in-process builds, `run watch`, joining mid-run) replays the same
//! events.jsonl, so they cannot tell different stories.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use indicatif::{ProgressBar, ProgressStyle};

use crate::ci::events::{self, Event};
use crate::ci::facts::{TestOutcome, TestResult};
use crate::ci::report::Report;
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
    /// Start order, so the named few are the longest-running builds.
    building: Vec<String>,
    /// PhaseStarted stamps by task id, so the finish line can say how long
    /// the task took.
    phase_started: std::collections::BTreeMap<String, u64>,
}

pub(crate) fn glyph(status: TaskStatus) -> &'static str {
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
            building: Vec::new(),
            phase_started: std::collections::BTreeMap::new(),
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
            // Once-a-minute liveness with fresh counts, in quiet stretches
            // and through chatty compiles alike.
            Event::Heartbeat { at, detail } => {
                let mut progress = self.progress();
                if let Some(detail) = detail {
                    if progress.is_empty() {
                        progress = detail.clone();
                    } else {
                        progress = format!("{progress} · {detail}");
                    }
                }
                if self.bar.is_none() && !progress.is_empty() {
                    vec![format!("{} {}", self.stamp(*at), progress)]
                } else {
                    Vec::new()
                }
            }
            // Starts feed the in-flight set the milestone lines and the bar
            // show; a line per start would drown the narration.
            Event::JobStarted { job, .. } => {
                if !self.building.iter().any(|started| started == job.as_str()) {
                    self.building.push(job.to_string());
                }
                Vec::new()
            }
            Event::PhaseStarted {
                at,
                label,
                jobs,
                task_id,
            } => {
                self.total_jobs += jobs.unwrap_or(0);
                self.phase_started.insert(task_id.clone(), *at);
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
                let took = self
                    .phase_started
                    .remove(task_id)
                    .map(|started| {
                        format!(" · took {}", format::duration(at.saturating_sub(started) as f64))
                    })
                    .unwrap_or_default();
                vec![format!(
                    "{} {} {task_id} · {headline}{took}",
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
                self.building.retain(|started| started != job.as_str());
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

pub(crate) fn test_summary(label: &str, tests: &[&TestResult]) -> Option<String> {
    if tests.is_empty() {
        return None;
    }
    let outcomes = [
        TestOutcome::Pass,
        TestOutcome::Xfail,
        TestOutcome::Broken,
        TestOutcome::Fail,
        TestOutcome::Xpass,
        TestOutcome::Skipped,
    ];
    let mut parts = vec![format!("{} total", tests.len())];
    for outcome in outcomes {
        let count = tests.iter().filter(|test| test.outcome == outcome).count();
        if count > 0 {
            parts.push(format!("{count} {}", outcome.as_str()));
        }
    }
    Some(format!("{label}: {}", crate::support::ui::counts(&parts)))
}

/// Render the stable, folded answer shared by direct builds and `run report`.
pub fn finished_report(report: &Report) {
    crate::support::ui::result(&report.title);
    let tests: Vec<&TestResult> = report.tests.values().flatten().collect();
    if let Some(line) = test_summary("tests", &tests) {
        crate::support::ui::result(line);
    }
    let upstream: Vec<&TestResult> = tests
        .iter()
        .copied()
        .filter(|test| test.test_name.as_deref() == Some("upstream"))
        .collect();
    if let Some(line) = test_summary("upstream", &upstream) {
        crate::support::ui::result(line);
    }
    for (family, label) in [("library", "upstream libraries"), ("wheel", "upstream wheels")] {
        let family_tests: Vec<&TestResult> = upstream
            .iter()
            .copied()
            .filter(|test| test.test_family.as_deref() == Some(family))
            .collect();
        if let Some(line) = test_summary(label, &family_tests) {
            crate::support::ui::result(line);
        }
    }
    for task in &report.tasks {
        if !task.enabled {
            continue;
        }
        let took = task
            .elapsed_seconds
            .map(|elapsed| format!(" · took {elapsed}"))
            .unwrap_or_default();
        crate::support::ui::result(format!(
            "  {} {}: {}{took}",
            glyph(task.status),
            task.task_id,
            task.headline
        ));
    }
}
