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
    /// Fold the last N CI runs instead of a commit range. A pull request's
    /// head is not an ancestor of main once it lands, so a range over main
    /// cannot reach the runs that did the building.
    #[arg(long, conflicts_with = "range", value_name = "N")]
    pub runs: Option<usize>,
    #[arg(long, default_value = "build.yml")]
    pub workflow: String,
    #[arg(long)]
    pub repository: Option<String>,
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
    /// What was folded: a commit range, or a count of runs.
    pub range: String,
    /// Revisions looked at, and how many of them published anything. A fold
    /// mostly missing its records reads as "nothing got slower".
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
    /// The event whose run measured it, when the runs API named one.
    event: Option<String>,
    map: Option<EvalMap>,
    steps: Option<StepTimings>,
}

/// One revision CI ran on, and what ran it.
struct Ran {
    rev: String,
    event: Option<String>,
}

/// The revisions the workflow actually ran on, newest first. A rebase-merge
/// gives a landed pull request a new sha, so its run's head is reachable
/// from no branch; the runs API is where those revisions still exist.
fn ran_revisions(repository: &str, workflow: &str, limit: usize) -> Result<Vec<Ran>> {
    let client = crate::github::client::Client::new(crate::github::client::token().as_deref());
    let mut seen = std::collections::BTreeSet::new();
    let mut found = Vec::new();
    for page in 1..=20u32 {
        let value = client.get(&format!(
            "repos/{repository}/actions/workflows/{workflow}/runs?per_page=100&page={page}"
        ))?;
        let Some(runs) = value["workflow_runs"].as_array().filter(|runs| !runs.is_empty()) else {
            break;
        };
        for run in runs {
            let Some(rev) = run["head_sha"].as_str() else {
                continue;
            };
            // One revision can carry several runs (a re-run, a pull request
            // and the merge queue behind it); its records are published once.
            if seen.insert(rev.to_string()) {
                found.push(Ran {
                    rev: rev.to_string(),
                    event: run["event"].as_str().map(str::to_string),
                });
            }
            if found.len() >= limit {
                return Ok(found);
            }
        }
    }
    Ok(found)
}

/// The tree a revision names. Local when the repository has the commit, and
/// from the API when it does not, which is the whole point of folding runs.
fn tree_of(repo: &std::path::Path, repository: &str, rev: &str) -> Option<String> {
    if let Ok(tree) = crate::support::git::git(repo, &["rev-parse", &format!("{rev}^{{tree}}")]) {
        return Some(tree);
    }
    let client = crate::github::client::Client::new(crate::github::client::token().as_deref());
    let value = client.get(&format!("repos/{repository}/commits/{rev}")).ok()?;
    value["commit"]["tree"]["sha"].as_str().map(str::to_string)
}

fn published(repo: &std::path::Path, repository: &str, ran: &[Ran]) -> Vec<Published> {
    let map_template = crate::ci::baseline::map_url_template();
    let step_template = crate::ci::steps::url_template();
    ran.iter()
        .map(|ran| Published {
            // The eval map is keyed by tree and the steps by revision: the
            // tree determines the evaluation, while a run belongs to a commit.
            map: tree_of(repo, repository, &ran.rev)
                .and_then(|tree| crate::ci::baseline::fetch(&tree, &map_template, None)),
            steps: crate::ci::steps::fetch(&ran.rev, &step_template),
            rev: ran.rev.clone(),
            event: ran.event.clone(),
        })
        .collect()
}

/// The revisions a commit range names, oldest first.
fn ranged(repo: &std::path::Path, range: &str) -> Result<Vec<Ran>> {
    Ok(crate::support::git::git(repo, &["rev-list", "--reverse", range])?
        .lines()
        .map(|rev| Ran {
            rev: rev.to_string(),
            event: None,
        })
        .collect())
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
                // The event tells a merge-queue build from the pull request
                // behind it, which is where the same tree costs twice.
                let name = match &record.event {
                    Some(event) => format!("{} {event}", format::short_rev(&record.rev)),
                    None => format::short_rev(&record.rev).to_string(),
                };
                add(name, build + steps);
            }
        }
    }
    folded
}

pub fn run(args: TimingsArgs) -> Result<crate::support::process::CommandStatus> {
    let repo = crate::support::git::repo_root()?;
    let repository = crate::github::surfaces::resolve_repository(args.repository.as_deref(), &repo)?;
    let (ran, over) = match args.runs {
        Some(limit) => (
            ran_revisions(&repository, &args.workflow, limit)?,
            format!("{limit} runs of {}", args.workflow),
        ),
        None => (ranged(&repo, &args.range)?, args.range.clone()),
    };
    let published = published(&repo, &repository, &ran);
    let mut series: Vec<Series> = series(&published, args.by)
        .into_iter()
        .filter(|(_, series)| series.total >= args.floor)
        .map(|(name, series)| Series { name, ..series })
        .collect();
    series.sort_by(|a, b| b.total.total_cmp(&a.total));
    let report = Report {
        range: over,
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
            "{} of {} revisions published timings",
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
