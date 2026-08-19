//! Fold the timings published across a commit range. Each build publishes
//! its own record and nothing reads them back, so "what got slower, and
//! when" needs one pass over the range rather than one run at a time.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ci::evalmap::EvalMap;
use crate::ci::steps::StepTimings;
use crate::support::error::Result;
use crate::support::schema::Document;
use crate::support::{format, ui};

/// What a row groups by. A run's cost splits three ways, and each answers a
/// different question: which package, which pipeline phase, which CI step.
#[derive(Clone, Copy, PartialEq, clap::ValueEnum)]
pub enum By {
    /// Nix jobs, the build itself
    Job,
    /// Pipeline tasks: formatting, input warming, evaluation, the build union
    Task,
    /// Workflow steps, which is where setup cost hides
    Step,
    /// One row per commit
    Rev,
}

#[derive(clap::Args)]
pub struct TimingsArgs {
    /// Commit range to fold, e.g. `main~50..main`
    #[arg(default_value = "HEAD~20..HEAD")]
    pub range: String,
    #[arg(long, value_enum, default_value_t = By::Job)]
    pub by: By,
    /// Rows to print; the longest come first
    #[arg(long, default_value_t = 25)]
    pub limit: usize,
    /// Drop rows below this many seconds of total time
    #[arg(long, default_value_t = 1.0)]
    pub floor: f64,
    #[command(flatten)]
    pub json: ui::JsonArg,
}

/// One name's time across the range. First and last are the ends of the
/// series, which is what shows a regression; the mean alone hides it.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Series {
    #[serde(default)]
    pub name: String,
    pub total: f64,
    pub runs: usize,
    pub first: f64,
    pub last: f64,
}

/// The fold's answer: what was measured, and the series it found.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub range: String,
    /// Commits in the range, and how many of them published anything. A
    /// range mostly missing its records reads as "nothing got slower".
    pub commits: usize,
    pub published: usize,
    pub series: Vec<Series>,
}

impl Document for Report {
    const KIND: &'static str = "timings";
    const SCHEMA: u32 = 1;
}

impl Series {
    fn add(&mut self, seconds: f64) {
        if self.runs == 0 {
            self.first = seconds;
        }
        self.last = seconds;
        self.total += seconds;
        self.runs += 1;
    }
}

/// A revision's published records. Either may be missing: a build that never
/// published, or a run older than the step-timings document.
struct Published {
    rev: String,
    map: Option<EvalMap>,
    steps: Option<StepTimings>,
}

fn published(repo: &std::path::Path, range: &str) -> Result<Vec<Published>> {
    let revs = crate::support::git::git(repo, &["rev-list", "--reverse", range])?;
    let map_template = crate::ci::baseline::map_url_template();
    let step_template = crate::ci::steps::url_template();
    let mut found = Vec::new();
    for rev in revs.lines() {
        let tree = crate::support::git::git(repo, &["rev-parse", &format!("{rev}^{{tree}}")])?;
        // The eval map is keyed by tree and the steps by revision: the tree
        // determines the evaluation, while a workflow run belongs to a commit.
        found.push(Published {
            rev: rev.to_string(),
            map: crate::ci::baseline::fetch(&tree, &map_template, None),
            steps: crate::ci::steps::fetch(rev, &step_template),
        });
    }
    Ok(found)
}

fn series(published: &[Published], by: By) -> BTreeMap<String, Series> {
    let mut folded: BTreeMap<String, Series> = BTreeMap::new();
    for record in published {
        let mut add = |name: String, seconds: f64| {
            folded.entry(name).or_default().add(seconds);
        };
        match by {
            By::Job => {
                for (job, seconds) in record.map.iter().flat_map(|map| &map.build_seconds) {
                    add(job.as_str().to_string(), *seconds);
                }
            }
            By::Task => {
                for task in record.map.iter().flat_map(|map| &map.task_seconds) {
                    add(task.label.clone(), task.seconds);
                }
            }
            By::Step => {
                for job in record.steps.iter().flat_map(|steps| &steps.jobs) {
                    for step in &job.steps {
                        add(format!("{} · {}", job.name, step.name), step.seconds.0);
                    }
                }
            }
            By::Rev => {
                let build: f64 = record
                    .map
                    .iter()
                    .flat_map(|map| map.build_seconds.values())
                    .sum();
                let steps: f64 = record
                    .steps
                    .iter()
                    .flat_map(|steps| &steps.jobs)
                    .map(|job| job.seconds.0)
                    .sum();
                add(format::short_rev(&record.rev).to_string(), build + steps);
            }
        }
    }
    folded
}

pub fn run(args: TimingsArgs) -> Result<crate::support::process::CommandStatus> {
    let repo = crate::support::git::repo_root()?;
    let published = published(&repo, &args.range)?;
    let mut series: Vec<Series> = series(&published, args.by)
        .into_iter()
        .filter(|(_, series)| series.total >= args.floor)
        .map(|(name, series)| Series { name, ..series })
        .collect();
    series.sort_by(|a, b| b.total.total_cmp(&a.total));
    let report = Report {
        range: args.range.clone(),
        commits: published.len(),
        published: published
            .iter()
            .filter(|record| record.map.is_some() || record.steps.is_some())
            .count(),
        series,
    };
    ui::emit(&args.json, &report, |report| human(report, args.limit))?;
    Ok(crate::support::process::CommandStatus::SUCCESS)
}

fn human(report: &Report, limit: usize) {
    ui::fact(
        "range",
        format!(
            "{} of {} commits published timings",
            report.published, report.commits
        ),
    );
    let rows: Vec<Vec<String>> = report
        .series
        .iter()
        .take(limit)
        .map(|series| {
            vec![
                series.name.clone(),
                format::duration(series.total),
                series.runs.to_string(),
                format!(
                    "{} \u{2192} {}",
                    format::duration(series.first),
                    format::duration(series.last)
                ),
            ]
        })
        .collect();
    ui::output(crate::support::table::render(
        Some(&["name", "total", "runs", "first \u{2192} last"]),
        &rows,
    ));
    let dropped = report.series.len().saturating_sub(limit);
    if dropped > 0 {
        ui::fact("not shown", format!("{dropped} more rows"));
    }
}
