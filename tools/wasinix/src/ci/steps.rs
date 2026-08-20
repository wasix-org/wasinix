//! A workflow run's step durations, published so they outlive it. GitHub
//! keeps step records only as long as the run's logs, and a setup step that
//! grew a minute is invisible from any single run.

use serde::{Deserialize, Serialize};

use crate::support::atoms::{DurationSecs, Rev};
use crate::support::error::{Result, request_error};
use crate::support::schema::Document;

/// Steps shorter than this are runner bookkeeping, not signal, and there are
/// hundreds of them across a run.
const FLOOR_SECONDS: f64 = 1.0;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Step {
    pub name: String,
    pub seconds: DurationSecs,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Job {
    pub name: String,
    pub seconds: DurationSecs,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub steps: Vec<Step>,
}

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StepTimings {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub rev: Option<Rev>,
    pub run_id: u64,
    pub workflow: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub jobs: Vec<Job>,
}

impl Document for StepTimings {
    const KIND: &'static str = "stepTimings";
    const SCHEMA: u32 = 1;
}

/// The key a run's steps publish under. Keyed by revision, not run id, so a
/// fold walking a commit range needs no listing; a re-run overwrites.
pub fn key(rev: &str) -> String {
    format!("step-timings/{rev}.json")
}

fn seconds_between(value: &serde_json::Value, from: &str, to: &str) -> Option<f64> {
    let at = |field: &str| crate::support::time::parse_utc(value[field].as_str()?);
    Some(at(to)?.saturating_sub(at(from)?) as f64)
}

/// One run's jobs and their steps, from the run's own records. A job still
/// running has no duration and is left out rather than counted as zero.
pub fn collect(
    client: &crate::github::client::Client,
    repository: &str,
    run_id: u64,
    rev: Option<Rev>,
    workflow: &str,
) -> Result<StepTimings> {
    let value = client.get(&format!(
        "repos/{repository}/actions/runs/{run_id}/jobs?per_page=100"
    ))?;
    let Some(entries) = value["jobs"].as_array() else {
        return request_error(format!("run {run_id} reported no jobs"));
    };
    let mut jobs = Vec::new();
    for entry in entries {
        let Some(seconds) = seconds_between(entry, "started_at", "completed_at") else {
            continue;
        };
        let steps = entry["steps"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|step| {
                let seconds = seconds_between(step, "started_at", "completed_at")?;
                (seconds >= FLOOR_SECONDS).then(|| Step {
                    name: step["name"].as_str().unwrap_or_default().to_string(),
                    seconds: DurationSecs(seconds),
                })
            })
            .collect();
        jobs.push(Job {
            name: entry["name"].as_str().unwrap_or_default().to_string(),
            seconds: DurationSecs(seconds),
            steps,
        });
    }
    Ok(StepTimings {
        rev,
        run_id,
        workflow: workflow.to_string(),
        jobs,
    })
}

impl StepTimings {
    /// The step-summary projection: one table per job, longest step first.
    pub fn summary(&self) -> String {
        let mut text = String::from("## Step timings\n");
        for job in &self.jobs {
            text.push_str(&format!(
                "\n### {} · {}\n\n| step | time |\n|:--|--:|\n",
                job.name, job.seconds
            ));
            let mut steps: Vec<&Step> = job.steps.iter().collect();
            steps.sort_by(|a, b| b.seconds.0.total_cmp(&a.seconds.0));
            for step in steps {
                text.push_str(&format!("| {} | {} |\n", step.name, step.seconds));
            }
        }
        text
    }

    /// Upload under the revision's key, next to the eval maps a build
    /// publishes.
    pub fn publish(&self, effects: crate::support::effects::Effects) -> Result<()> {
        let Some(rev) = &self.rev else {
            return request_error("publishing step timings needs the run's revision");
        };
        let scratch = crate::support::fs::Scratch::create("wasinix-step-timings")?;
        let file = scratch.path().join("step-timings.json");
        crate::support::schema::write(&file, self)?;
        if effects.is_dry_run() {
            crate::support::ui::fact(
                "step timings",
                format!("skipped (dry run), {}", key(rev.full())),
            );
            return Ok(());
        }
        let mut cmd = std::process::Command::new("aws");
        cmd.args(["s3", "cp", "--no-progress"])
            .arg(&file)
            .arg(format!(
                "s3://{}/{}",
                crate::support::nix::CACHE_BUCKET,
                key(rev.full())
            ))
            .args(["--endpoint-url", crate::support::nix::CACHE_ENDPOINT]);
        crate::support::tools::checked_output(&mut cmd, "publishing the step timings")?;
        crate::support::ui::fact("step timings published", key(rev.full()));
        Ok(())
    }
}

/// The published steps for a revision, or None with the reason surfaced. A
/// run that never published is a gap in the series, never an error.
pub fn fetch(rev: &str, url_template: &str) -> Option<StepTimings> {
    let url = url_template.replace("{key}", &key(rev));
    let value = if url.contains("://") {
        crate::support::http::get_json(&url)
    } else {
        crate::support::json::read(std::path::Path::new(&url))
    };
    crate::support::schema::from_value(value.ok()?, &url).ok()
}

/// The template the fold reads; tests substitute a local directory's.
pub fn url_template() -> String {
    format!("{}/{{key}}", crate::support::nix::CACHE_SUBSTITUTER)
}
