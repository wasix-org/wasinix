//! Terminal renderers over the run's event stream. Every progress view
//! (in-process builds, `run watch`, joining mid-run) replays the same
//! events.jsonl, so they cannot tell different stories.

use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use indicatif::{ProgressBar, ProgressStyle};

use crate::ci::events::{self, Event, ProgressSink};
use crate::ci::facts::{Diagnostic, DiagnosticSeverity, FailureCause, TestOutcome, TestResult};
use crate::ci::report::{Conclusion, Report};
use crate::ci::types::RequestAction;
use crate::support::atoms::{JobStatus, TaskStatus};
use crate::support::error::Result;
use crate::support::format;
use crate::support::terminal::interactive;

/// How many failure-detail lines one job may print.
const FAILURE_DETAIL_LINES: usize = 6;
const MILESTONE_EVERY: usize = 50;
const LIVENESS_SECONDS: u64 = 60;

#[derive(Clone, Copy)]
pub(crate) enum Narration {
    Build,
    Watch,
}

struct ActivePhase {
    label: String,
    started_at: u64,
}

pub struct LineRenderer {
    started_at: Option<u64>,
    bar: Option<ProgressBar>,
    bar_started: bool,
    narration: Narration,
    total_jobs: usize,
    completed: usize,
    incomplete: usize,
    /// Start order, so the named few are the longest-running realisations.
    realising: Vec<String>,
    phases: std::collections::BTreeMap<String, ActivePhase>,
    last_liveness_at: Option<u64>,
    heartbeat_detail: Option<String>,
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

fn display_label(label: &str) -> String {
    if crate::support::ui::verbosity() == crate::support::ui::Verbosity::Verbose {
        return label.to_string();
    }
    label.strip_prefix("case: ").unwrap_or(label).to_string()
}

fn display_headline(task_id: &str, headline: &str) -> String {
    if crate::support::ui::verbosity() == crate::support::ui::Verbosity::Verbose {
        return headline.to_string();
    }
    if task_id.ends_with(".baseline") {
        return if headline.starts_with("not reused:") {
            "no reusable result".to_string()
        } else {
            "previous results reused".to_string()
        };
    }
    headline.to_string()
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
        LineRenderer::with_options(interactive(), Narration::Watch)
    }

    pub(crate) fn for_build() -> LineRenderer {
        LineRenderer::with_options(interactive(), Narration::Build)
    }

    /// The spinner decision made explicit: a spinner absorbs the milestone
    /// lines, and a nix sandbox runs builders on a pseudoterminal, so a test
    /// pinning the narration must choose line mode rather than detect it.
    #[cfg(test)]
    pub(crate) fn with_spinner(spinner: bool) -> LineRenderer {
        LineRenderer::with_options(spinner, Narration::Watch)
    }

    fn with_options(spinner: bool, narration: Narration) -> LineRenderer {
        let bar = spinner.then(|| {
            ProgressBar::new_spinner().with_style(
                ProgressStyle::with_template("{spinner} {msg}").expect("the template is static"),
            )
        });
        LineRenderer {
            started_at: None,
            bar,
            bar_started: false,
            narration,
            total_jobs: 0,
            completed: 0,
            incomplete: 0,
            realising: Vec::new(),
            phases: std::collections::BTreeMap::new(),
            last_liveness_at: None,
            heartbeat_detail: None,
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
        if self.incomplete > 0 {
            parts.push(format!("{} not completed", self.incomplete));
        }
        crate::support::ui::counts(&parts)
    }

    /// [`counts`](Self::counts) plus the work in flight, for the lines
    /// describing a run still going.
    fn progress(&self, at: u64) -> String {
        let counts = self.counts();
        let work = if !self.realising.is_empty() {
            let names: Vec<&str> = self.realising.iter().map(String::as_str).collect();
            format!("realising {}", format::some(&names, 3))
        } else if let Some(detail) = &self.heartbeat_detail {
            detail.clone()
        } else if let Some(phase) = self.phases.values().min_by_key(|phase| phase.started_at) {
            let label = if self.phases.len() == 1 {
                display_label(&phase.label)
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
            Event::Heartbeat { detail, .. } => {
                self.heartbeat_detail.clone_from(detail);
                Vec::new()
            }
            // Starts feed the in-flight set the milestone lines and the bar
            // show; a line per start would drown the narration.
            Event::JobStarted { job, .. } => {
                if !self.realising.iter().any(|started| started == job.as_str()) {
                    self.realising.push(job.to_string());
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
                vec![format!(
                    "{} {}{size}",
                    self.stamp(*at),
                    display_label(label)
                )]
            }
            Event::PhaseFinished {
                at,
                status,
                headline,
                task_id,
            } => {
                let finished = self.phases.remove(task_id);
                let label = finished
                    .as_ref()
                    .map(|phase| display_label(&phase.label))
                    .unwrap_or_else(|| task_id.clone());
                let took = finished
                    .map(|started| {
                        format!(
                            " · took {}",
                            format::duration(at.saturating_sub(started.started_at) as f64)
                        )
                    })
                    .unwrap_or_default();
                vec![format!(
                    "{} {} {label} · {}{took}",
                    self.stamp(*at),
                    glyph(*status),
                    display_headline(task_id, headline)
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
                self.realising.retain(|started| started != job.as_str());
                if *status == JobStatus::Failure {
                    self.incomplete += 1;
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
                } else {
                    Vec::new()
                }
            }
            Event::Warning { at, message } => {
                vec![format!("{} warning: {message}", self.stamp(*at))]
            }
            Event::ResourceSample { .. } | Event::AutomaticGc { .. } => Vec::new(),
            Event::LegacyOutput { .. } => Vec::new(),
            Event::Diagnostic { at, diagnostic } => {
                self.unexplained_failures = 0;
                self.diagnostic_lines(*at, diagnostic)
            }
            Event::RunFinished { at, state, .. } => {
                if matches!(self.narration, Narration::Build) {
                    return Vec::new();
                }
                let mut lines = Vec::new();
                if self.unexplained_failures > 0 {
                    lines.push(format!(
                        "{} ✗ {} jobs failed before producing a log",
                        self.stamp(*at),
                        self.unexplained_failures
                    ));
                    self.unexplained_failures = 0;
                }
                let mut parts = vec![format!("Run {state}")];
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

    pub(crate) fn lines_for_events(&mut self, events: &[Event]) -> Vec<String> {
        let mut lines = Vec::new();
        let mut milestone_at = None;
        for event in events {
            if matches!(event, Event::RunFinished { .. }) {
                if let Some(at) = milestone_at.take() {
                    lines.push(format!("{} {}", self.stamp(at), self.progress(at)));
                }
            }
            let success = matches!(
                event,
                Event::JobFinished {
                    status: JobStatus::Success,
                    ..
                }
            );
            lines.extend(self.lines_for(event));
            if success && self.completed.is_multiple_of(MILESTONE_EVERY) && self.bar.is_none() {
                milestone_at = Some(event.at());
            }
        }
        if let Some(at) = milestone_at {
            lines.push(format!("{} {}", self.stamp(at), self.progress(at)));
        }
        lines
    }

    pub fn events(&mut self, events: &[Event]) {
        for line in self.lines_for_events(events) {
            self.line(line);
        }
        if events
            .iter()
            .any(|event| matches!(event, Event::RunFinished { .. }))
        {
            if let Some(bar) = self.bar.take() {
                bar.finish_and_clear();
            }
            return;
        }
        if let (Some(bar), Some(last)) = (&self.bar, events.last()) {
            let progress = self.progress(last.at());
            let start = !progress.is_empty() && !self.bar_started;
            bar.set_message(progress);
            if start {
                bar.enable_steady_tick(Duration::from_millis(120));
                self.bar_started = true;
            }
        }
    }

    pub fn event(&mut self, event: &Event) {
        self.events(std::slice::from_ref(event));
    }

    pub(crate) fn lines_for_tick(&mut self, at: u64) -> Vec<String> {
        if let Some(bar) = &self.bar {
            let progress = self.progress(at);
            if !progress.is_empty() {
                bar.set_message(progress);
            }
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

    fn observe(&mut self, events: &[Event]) {
        LineRenderer::events(self, events);
        LineRenderer::tick(self, crate::support::time::unix_secs());
    }
}

/// Follow a run directory's stream until the run finishes (or `stop` is set
/// and the stream is drained), rendering as it goes.
pub fn follow(run_dir: &Path, stop: &AtomicBool) -> Result<()> {
    let mut renderer = LineRenderer::for_build();
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

#[derive(Clone, Copy)]
pub(crate) enum ReportView<'a> {
    Build(&'a Path),
    Stored,
}

pub(crate) fn report_title(report: &Report) -> String {
    let subject = match report.request.as_ref().map(|request| &request.action) {
        Some(RequestAction::Build(_)) => "Build",
        Some(RequestAction::Spot(_)) => "Spot build",
        Some(RequestAction::Diff(_)) => "Comparison",
        None => return report.title.clone(),
    };
    let outcome = match report.conclusion {
        Some(Conclusion::Success) => "succeeded",
        Some(Conclusion::Failure) => "failed",
        Some(Conclusion::Neutral) => "inconclusive",
        Some(Conclusion::Blocked) => "blocked",
        None => "in progress",
    };
    let elapsed = match (report.started_at, report.finished_at) {
        (Some(started), Some(finished)) => format!(
            " after {}",
            format::duration(finished.saturating_sub(started) as f64)
        ),
        _ => String::new(),
    };
    format!("{subject} {outcome}{elapsed}")
}

pub(crate) fn failure_summary(report: &Report) -> Option<String> {
    let mut failed = std::collections::BTreeSet::new();
    let mut blocked = std::collections::BTreeSet::new();
    for failure in report.failures.values().flatten() {
        if failure.cause == FailureCause::Transitive {
            blocked.insert(failure.job.as_str());
        } else {
            failed.insert(failure.job.as_str());
        }
    }
    let mut parts = Vec::new();
    if !failed.is_empty() {
        parts.push(format!("{} failed", failed.len()));
    }
    if !blocked.is_empty() {
        parts.push(format!("{} blocked", blocked.len()));
    }
    (!parts.is_empty()).then(|| format!("Jobs: {}", crate::support::ui::counts(&parts)))
}

fn failed_test_summary(tests: &[&TestResult]) -> Option<String> {
    let failed = tests
        .iter()
        .filter(|test| matches!(test.outcome, TestOutcome::Fail | TestOutcome::Xpass))
        .count();
    (failed > 0).then(|| format!("Tests: {failed} failed out of {}", tests.len()))
}

pub(crate) fn report_lines(report: &Report, view: ReportView<'_>, verbose: bool) -> Vec<String> {
    let mut lines = Vec::new();
    if matches!(view, ReportView::Build(_)) {
        lines.push(String::new());
    }
    lines.push(report_title(report));
    for diagnostic in &report.diagnostics {
        for line in diagnostic_lines(diagnostic) {
            lines.push(format!("  {line}"));
        }
    }
    if let Some(line) = failure_summary(report) {
        lines.push(line);
    }
    if verbose && !report.log_retention.is_empty() {
        let mut parts = vec![
            format!("{} logs", report.log_retention.log_count),
            format!("{} retained", report.log_retention.retained_bytes),
            format!("{} produced", report.log_retention.original_bytes),
        ];
        if report.log_retention.omitted_bytes.0 > 0 {
            parts.push(format!("{} omitted", report.log_retention.omitted_bytes));
        }
        lines.push(format!("logs: {}", crate::support::ui::counts(&parts)));
    }
    if verbose && !report.resources.is_empty() {
        let mut parts = Vec::new();
        if let Some(available) = report.resources.minimum_store_available_bytes {
            parts.push(format!("{available} available at low point"));
        }
        if let Some(total) = report.resources.store_total_bytes {
            parts.push(format!("{total} total"));
        }
        if report.resources.automatic_gc_runs == 0 {
            parts.push("automatic GC did not run".to_string());
        } else {
            parts.push(format!(
                "automatic GC ran {} times · {} requested",
                report.resources.automatic_gc_runs, report.resources.automatic_gc_requested_bytes
            ));
        }
        lines.push(format!("store: {}", crate::support::ui::counts(&parts)));
    }
    let tests: Vec<&TestResult> = report.tests.values().flatten().collect();
    if verbose {
        if let Some(line) = test_summary("tests", &tests) {
            lines.push(line);
        }
        let upstream: Vec<&TestResult> = tests
            .iter()
            .copied()
            .filter(|test| test.test_name.as_deref() == Some("upstream"))
            .collect();
        if let Some(line) = test_summary("upstream", &upstream) {
            lines.push(line);
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
                lines.push(line);
            }
        }
    } else if let Some(line) = failed_test_summary(&tests) {
        lines.push(line);
    }
    if matches!(view, ReportView::Stored) || verbose {
        for task in &report.tasks {
            if !task.enabled {
                continue;
            }
            let took = task
                .elapsed_seconds
                .map(|elapsed| format!(" · took {elapsed}"))
                .unwrap_or_default();
            let label = if verbose {
                task.task_id.clone()
            } else {
                display_label(&task.label)
            };
            let space = if verbose {
                match (
                    task.store_available_start_bytes,
                    task.store_available_finish_bytes,
                ) {
                    (Some(start), Some(finish)) => {
                        format!(" · store {start} → {finish} available")
                    }
                    _ => String::new(),
                }
            } else {
                String::new()
            };
            lines.push(format!(
                "  {} {label}: {}{took}{space}",
                glyph(task.status),
                task.headline
            ));
        }
    }
    if let ReportView::Build(run_dir) = view {
        if report.conclusion != Some(Conclusion::Success) {
            let run = crate::support::shell::quote(&run_dir.to_string_lossy());
            lines.push(String::new());
            if !report.failures.is_empty() {
                lines.push(format!("Inspect failures: wasinix run failures {run}"));
            }
            lines.push(format!("Inspect logs: wasinix run logs {run}"));
        }
    }
    lines
}

/// Render the stable, folded answer shared by direct builds and `run report`.
pub(crate) fn finished_report(report: &Report, view: ReportView<'_>) {
    let verbose = crate::support::ui::verbosity() == crate::support::ui::Verbosity::Verbose;
    for line in report_lines(report, view, verbose) {
        crate::support::ui::result(line);
    }
}
