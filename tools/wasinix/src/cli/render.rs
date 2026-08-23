//! Terminal renderers over the run's event stream. Every progress view
//! (in-process builds, `run watch`, joining mid-run) replays the same
//! events.jsonl, so they cannot tell different stories.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use indicatif::{ProgressBar, ProgressStyle};

use crate::ci::events::{self, Event, ProgressSink};
use crate::ci::facts::{Diagnostic, DiagnosticSeverity, TestOutcome, TestResult};
use crate::ci::report::Report;
use crate::support::atoms::{JobStatus, TaskStatus};
use crate::support::error::Result;
use crate::support::format;
use crate::support::terminal::interactive;

/// How many failure-detail lines one job may print.
const FAILURE_DETAIL_LINES: usize = 6;
const MILESTONE_EVERY: usize = 50;
const LIVENESS_SECONDS: u64 = 60;

struct ActivePhase {
    label: String,
    started_at: u64,
}

pub struct LineRenderer {
    started_at: Option<u64>,
    bar: Option<ProgressBar>,
    total_jobs: usize,
    completed: usize,
    failed: usize,
    /// Start order, so the named few are the longest-running builds.
    building: Vec<String>,
    phases: std::collections::BTreeMap<String, ActivePhase>,
    last_liveness_at: Option<u64>,
    unexplained_failures: usize,
}

pub(crate) fn glyph(status: TaskStatus) -> &'static str {
    match status {
        TaskStatus::Success => "✓",
        TaskStatus::Failure | TaskStatus::Cancelled => "✗",
        TaskStatus::Blocked => "⚠",
        TaskStatus::Skipped | TaskStatus::Deferred => "·",
        TaskStatus::Pending => "·",
    }
}

pub(crate) fn diagnostic_lines(diagnostic: &Diagnostic) -> Vec<String> {
    let glyph = match diagnostic.severity {
        DiagnosticSeverity::Warning => "warning:",
        DiagnosticSeverity::Error => "✗",
    };
    let mut lines = vec![format!("{glyph} {}", diagnostic.title)];
    lines.extend(
        diagnostic
            .message
            .lines()
            .take(FAILURE_DETAIL_LINES)
            .map(|line| format!("  │ {line}")),
    );
    if !diagnostic.affected_jobs.is_empty() {
        lines.push(format!(
            "  │ {} jobs did not complete",
            diagnostic.affected_jobs.len()
        ));
    }
    lines
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
                ProgressStyle::with_template("{spinner} {msg}").expect("the template is static"),
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
            phases: std::collections::BTreeMap::new(),
            last_liveness_at: None,
            unexplained_failures: 0,
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
    fn progress(&self, at: u64) -> String {
        let counts = self.counts();
        let work = if !self.building.is_empty() {
            let names: Vec<&str> = self.building.iter().map(String::as_str).collect();
            format!("building {}", format::some(&names, 3))
        } else if let Some(phase) = self.phases.values().min_by_key(|phase| phase.started_at) {
            let label = if self.phases.len() == 1 {
                phase.label.clone()
            } else {
                format!("{} phases running", self.phases.len())
            };
            format!(
                "{label} · running for {}",
                format::duration(at.saturating_sub(phase.started_at) as f64)
            )
        } else {
            String::new()
        };
        if counts.is_empty() {
            work
        } else if work.is_empty() {
            counts
        } else {
            crate::support::ui::counts(&[counts, work])
        }
    }

    fn diagnostic_lines(&self, at: u64, diagnostic: &Diagnostic) -> Vec<String> {
        let mut lines = diagnostic_lines(diagnostic);
        if let Some(first) = lines.first_mut() {
            *first = format!("{} {first}", self.stamp(at));
        }
        lines
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
                self.last_liveness_at = Some(*at);
                let mut progress = self.progress(*at);
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
                self.phases.insert(
                    task_id.clone(),
                    ActivePhase {
                        label: label.clone(),
                        started_at: *at,
                    },
                );
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
                    .phases
                    .remove(task_id)
                    .map(|started| {
                        format!(
                            " · took {}",
                            format::duration(at.saturating_sub(started.started_at) as f64)
                        )
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
                    if error.as_deref() == Some(crate::ci::facts::NO_BUILD_LOG) {
                        self.unexplained_failures += 1;
                        return Vec::new();
                    }
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
                    vec![format!("{} {}", self.stamp(*at), self.progress(*at))]
                } else {
                    Vec::new()
                }
            }
            Event::Warning { at, message } => {
                vec![format!("{} warning: {message}", self.stamp(*at))]
            }
            Event::LegacyOutput { .. } => Vec::new(),
            Event::Diagnostic { at, diagnostic } => {
                self.unexplained_failures = 0;
                self.diagnostic_lines(*at, diagnostic)
            }
            Event::RunFinished { at, state, .. } => {
                let mut lines = Vec::new();
                if self.unexplained_failures > 0 {
                    lines.push(format!(
                        "{} ✗ {} jobs failed before producing a log",
                        self.stamp(*at),
                        self.unexplained_failures
                    ));
                    self.unexplained_failures = 0;
                }
                let mut parts = vec![state.to_string()];
                let counts = self.counts();
                if !counts.is_empty() {
                    parts.push(counts);
                }
                lines.push(format!(
                    "{} {}",
                    self.stamp(*at),
                    crate::support::ui::counts(&parts)
                ));
                lines
            }
        }
    }

    pub fn event(&mut self, event: &Event) {
        for line in self.lines_for(event) {
            self.line(line);
        }
        if let Some(bar) = &self.bar {
            bar.set_message(self.progress(event.at()));
        }
    }

    pub(crate) fn lines_for_tick(&mut self, at: u64) -> Vec<String> {
        if let Some(bar) = &self.bar {
            bar.set_message(self.progress(at));
            return Vec::new();
        }
        if self.phases.is_empty()
            || self
                .last_liveness_at
                .is_some_and(|last| at.saturating_sub(last) < LIVENESS_SECONDS)
        {
            return Vec::new();
        }
        let started = self
            .phases
            .values()
            .map(|phase| phase.started_at)
            .min()
            .unwrap_or(at);
        if at.saturating_sub(started) < LIVENESS_SECONDS {
            return Vec::new();
        }
        self.last_liveness_at = Some(at);
        let progress = self.progress(at);
        (!progress.is_empty())
            .then(|| format!("{} {progress}", self.stamp(at)))
            .into_iter()
            .collect()
    }

    pub(crate) fn tick(&mut self, at: u64) {
        for line in self.lines_for_tick(at) {
            self.line(line);
        }
    }

    pub fn finish(self) {
        if let Some(bar) = self.bar {
            bar.finish_and_clear();
        }
    }
}

impl ProgressSink for LineRenderer {
    fn event(&mut self, event: &Event) {
        LineRenderer::event(self, event);
    }

    fn tick(&mut self, at: u64) {
        LineRenderer::tick(self, at);
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
            renderer.observe(fresh);
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
            renderer.observe(fresh);
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
    for diagnostic in &report.diagnostics {
        for line in diagnostic_lines(diagnostic) {
            crate::support::ui::result(format!("  {line}"));
        }
    }
    if !report.log_retention.is_empty() {
        let mut parts = vec![
            format!("{} logs", report.log_retention.log_count),
            format!("{} retained", report.log_retention.retained_bytes),
            format!("{} produced", report.log_retention.original_bytes),
        ];
        if report.log_retention.omitted_bytes.0 > 0 {
            parts.push(format!("{} omitted", report.log_retention.omitted_bytes));
        }
        crate::support::ui::result(format!("logs: {}", crate::support::ui::counts(&parts)));
    }
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
    for (family, label) in [
        ("library", "upstream libraries"),
        ("wheel", "upstream wheels"),
    ] {
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
