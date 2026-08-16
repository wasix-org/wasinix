//! Publish one run's report to its GitHub surfaces: the PR comment, the
//! check run, and the step summary, all rendered from the same report.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::json;

use crate::ci::events::Snapshot;
use crate::ci::report::{Fragment, Report};
use crate::github::markdown::{self, Links};
use crate::github::surfaces::{Registry, Surface};
use crate::support::error::Result;
use crate::github::client::Client;

pub struct Target {
    pub repository: String,
    pub pull_request: Option<u64>,
    pub head_sha: Option<String>,
    pub run_url: Option<String>,
    /// The login the bot's comments carry, which upsert matches against.
    pub author: String,
    /// The report came from a fork PR's own code, so its verdict is a claim,
    /// not a result: the check concludes neutral and the surfaces say so.
    pub untrusted: bool,
    /// Where publish_failure_logs put this run's logs, when it ran.
    pub log_base: Option<String>,
}

const UNTRUSTED_NOTICE: &str = "> [!NOTE]\n> This result was produced by this \
    pull request's own code and is advisory; it is not an authoritative CI \
    verdict.\n\n";

/// Every published body passes here, so an untrusted report cannot reach any
/// surface without its advisory notice.
fn with_notice(body: crate::github::sanitize::Markdown, target: &Target) -> crate::github::sanitize::Markdown {
    if target.untrusted {
        crate::github::sanitize::Markdown::constant(UNTRUSTED_NOTICE).push(body)
    } else {
        body
    }
}

pub struct Rendered {
    pub report: Report,
    pub fragments: BTreeMap<String, Fragment>,
    pub snapshot: Option<Snapshot>,
}

pub fn load(run_dir: &Path) -> Result<Rendered> {
    let report_path = crate::ci::prepare::report_path(run_dir);
    let report = if report_path.exists() {
        crate::support::schema::read(&report_path)?
    } else {
        // A run that died without folding a report (cancel, timeout, lost
        // supervisor) still publishes a terminal one, or its check run stays
        // in_progress forever and its comment says "building".
        let run: crate::runs::Run =
            crate::support::schema::read(&run_dir.join(crate::runs::RUN_FILE))?;
        if !run.state.is_final() {
            return Err(crate::support::error::Error::Failure(format!(
                "{} has no report and the run is still {}",
                run_dir.display(),
                run.state
            )));
        }
        crate::ci::report::from_run_state(&run)
    };
    let fragments =
        crate::ci::report::fragments_under(&crate::ci::prepare::fragments_dir(run_dir))?;
    let snapshot = crate::ci::events::read_snapshot(run_dir).ok();
    Ok(Rendered {
        report,
        fragments,
        snapshot,
    })
}

/// [`load`] for a run still executing: the same fold over the fragments
/// written so far, concluding nothing. None until the run has recorded its
/// plan, which is the earliest moment the surfaces have something to say.
pub(crate) fn load_running(
    run_dir: &Path,
    events: &[crate::ci::events::Event],
) -> Result<Option<Rendered>> {
    if !crate::ci::prepare::preparation_path(run_dir).exists() {
        return Ok(None);
    }
    let loaded = crate::ci::prepare::load(run_dir)?;
    let fragments =
        crate::ci::report::fragments_under(&crate::ci::prepare::fragments_dir(run_dir))?;
    let snapshot = crate::ci::events::fold_snapshot(events);
    let report = crate::ci::report::fold(
        &loaded.plan(),
        &fragments,
        crate::ci::report::FoldContext {
            baseline_case: loaded.baseline_case(),
            finished: false,
            started_at: snapshot.started_at,
            finished_at: None,
            request: Some(loaded.request.clone()),
        },
    );
    Ok(Some(Rendered {
        report,
        fragments,
        snapshot: Some(snapshot),
    }))
}

fn links(_rendered: &Rendered, target: &Target) -> Links {
    Links {
        run_url: target.run_url.clone(),
        sha: target
            .head_sha
            .as_deref()
            .and_then(|sha| crate::support::atoms::Rev::parse(sha).ok()),
        log_base: target.log_base.clone(),
    }
}

/// Upload each rendered failure's build log to the public cache bucket and
/// return the base URL rows link under. The logs come from the local store,
/// so this runs on the machine that built; a job whose log is gone is
/// skipped rather than fatal.
pub fn publish_failure_logs(
    run_dir: &Path,
    rendered: &Rendered,
    sha: &str,
    effects: crate::support::effects::Effects,
) -> Result<Option<String>> {
    let mut drvs: BTreeMap<String, String> = BTreeMap::new();
    if let Ok(cases) = std::fs::read_dir(crate::ci::prepare::cases_dir(run_dir)) {
        for case in cases.flatten() {
            let map_path = crate::ci::prepare::eval_map_path(&case.path());
            if !map_path.exists() {
                continue;
            }
            let map: crate::ci::evalmap::EvalMap = crate::support::schema::read(&map_path)?;
            drvs.extend(
                map.jobs
                    .iter()
                    .map(|(job, drv)| (job.as_str().to_string(), drv.clone())),
            );
        }
    }
    let scratch = crate::support::fs::Scratch::create("wasinix-failure-logs")?;
    let mut published = 0usize;
    for failures in rendered.report.failures.values() {
        for failure in failures {
            let Some(drv) = drvs.get(failure.job.as_str()) else {
                continue;
            };
            let Ok(log) = crate::support::nix::Invocation::plain("log")
                .local_only()
                .operand(drv)
                .probe("a job without a log has no page to publish")
            else {
                continue;
            };
            if !log.status.is_success() || log.stdout.is_empty() {
                continue;
            }
            crate::support::fs::write(
                &scratch.path().join(format!("{}.txt", failure.job.as_str())),
                &log.stdout,
            )?;
            published += 1;
        }
    }
    if published == 0 {
        return Ok(None);
    }
    let base = format!(
        "{}/logs/{sha}",
        crate::support::nix::CACHE_SUBSTITUTER
    );
    if effects.is_dry_run() {
        crate::support::ui::fact("failure logs", format!("skipped (dry run), {published} logs"));
        return Ok(Some(base));
    }
    let mut cmd = std::process::Command::new("aws");
    cmd.args(["s3", "cp", "--no-progress", "--recursive"])
        .arg(scratch.path())
        .arg(format!(
            "s3://{}/logs/{sha}",
            crate::support::nix::CACHE_BUCKET
        ))
        .args(["--content-type", "text/plain; charset=utf-8"])
        .args(["--endpoint-url", crate::support::nix::CACHE_ENDPOINT]);
    crate::support::tools::checked_output(&mut cmd, "publishing failure logs")?;
    crate::support::ui::fact("failure logs", format!("{published} at {base}"));
    Ok(Some(base))
}

/// Upsert the report comment through its states; the same surface carries
/// running, final, and invalid renders.
pub fn comment(
    client: &Client,
    rendered: &Rendered,
    target: &Target,
    reply_to: Option<u64>,
    effects: crate::support::effects::Effects,
) -> Result<Option<u64>> {
    let pull_request = target.pull_request.ok_or_else(|| {
        crate::support::error::Error::Request("publishing a comment needs a pull request".into())
    })?;
    let links = links(rendered, target);
    let body = with_notice(
        markdown::comment(
            &rendered.report,
            &rendered.fragments,
            rendered.snapshot.as_ref(),
            &links,
        ),
        target,
    );
    let mut registry = Registry::new(
        client,
        target.repository.clone(),
        pull_request,
        &target.author,
        effects,
    );
    let mut attributes = Vec::new();
    if let Some(sha) = &target.head_sha {
        attributes.push(("sha", sha.clone()));
    }
    let surface = match reply_to {
        Some(comment_id) => Surface::CiReportReply { comment_id },
        None => Surface::CiReport,
    };
    registry.upsert(&surface, &attributes, body)
}

/// Create or complete the one "Wasinix CI" check run on the head sha. A dry
/// run renders the projection and stops before touching the API.
pub fn check(
    client: &Client,
    rendered: &Rendered,
    target: &Target,
    effects: crate::support::effects::Effects,
) -> Result<()> {
    let head_sha = target.head_sha.as_deref().ok_or_else(|| {
        crate::support::error::Error::Request("publishing a check needs the head sha".into())
    })?;
    let links = links(rendered, target);
    let projected = markdown::check(&rendered.report, &rendered.fragments, &links);
    let mut body = json!({
        "name": "Wasinix CI",
        "head_sha": head_sha,
        "output": {
            "title": projected.title,
            "summary": projected.summary,
        },
    });
    // The checks API takes at most 50 annotations per request; the report
    // document keeps the full list.
    let annotations: Vec<_> = rendered
        .report
        .annotations
        .iter()
        .take(50)
        .map(|annotation| {
            json!({
                "path": annotation.path,
                "start_line": annotation.line,
                "end_line": annotation.line,
                "annotation_level": "failure",
                "title": annotation.title,
                "message": annotation.message,
            })
        })
        .collect();
    if !annotations.is_empty() {
        body["output"]["annotations"] = annotations.into();
    }
    match projected.conclusion {
        // An untrusted report cannot conclude success or failure: its verdict
        // was written by the PR's own code, so the check stays advisory and
        // never satisfies a required-status gate.
        Some(_) if target.untrusted => {
            body["status"] = "completed".into();
            body["conclusion"] = "neutral".into();
            body["output"]["title"] =
                format!("self-reported by the PR: {}", projected.title).into();
        }
        Some(conclusion) => {
            body["status"] = "completed".into();
            body["conclusion"] = conclusion.as_github().into();
        }
        None => {
            body["status"] = "in_progress".into();
        }
    }
    if let Some(url) = &target.run_url {
        body["details_url"] = url.as_str().into();
    }
    if effects.is_dry_run() {
        crate::support::ui::fact("check run", "skipped (dry run)");
        return Ok(());
    }
    // Reuse this sha's existing "Wasinix CI" check run so re-publishing updates
    // one authoritative status instead of stacking a duplicate each time, and
    // so a run left in_progress is later completed rather than stranded.
    let existing = client.get(&format!(
        "repos/{}/commits/{head_sha}/check-runs?check_name=Wasinix%20CI",
        target.repository
    ))?["check_runs"]
        .as_array()
        .and_then(|runs| runs.iter().filter_map(|run| run["id"].as_u64()).max());
    match existing {
        Some(id) => client.patch(&format!("repos/{}/check-runs/{id}", target.repository), &body)?,
        None => client.post(&format!("repos/{}/check-runs", target.repository), &body)?,
    };
    Ok(())
}

pub struct Watch<'a> {
    pub run_dir: &'a Path,
    pub interval: std::time::Duration,
    pub comment: bool,
    pub check: bool,
    pub reply_to: Option<u64>,
}

/// A sink for the run's event stream that republishes the surfaces while the
/// run executes: at most one update per interval, and nothing once the
/// stream is final, so the finished surfaces belong to the post-run publish.
pub struct Watcher<'a> {
    client: &'a Client,
    target: &'a Target,
    watch: Watch<'a>,
    effects: crate::support::effects::Effects,
    events: Vec<crate::ci::events::Event>,
    finished: bool,
    published_at: Option<std::time::Instant>,
    stale: bool,
}

impl<'a> Watcher<'a> {
    pub fn new(
        client: &'a Client,
        target: &'a Target,
        watch: Watch<'a>,
        effects: crate::support::effects::Effects,
    ) -> Watcher<'a> {
        Watcher {
            client,
            target,
            watch,
            effects,
            events: Vec::new(),
            finished: false,
            published_at: None,
            stale: true,
        }
    }

    pub fn observe(&mut self, fresh: &[crate::ci::events::Event]) {
        use crate::ci::events::Event;
        self.events.extend_from_slice(fresh);
        self.stale |= !fresh.is_empty();
        self.finished |= fresh
            .iter()
            .any(|event| matches!(event, Event::RunFinished { .. }));
        let due = self
            .published_at
            .is_none_or(|at| at.elapsed() >= self.watch.interval);
        if self.finished || !self.stale || !due {
            return;
        }
        match self.publish() {
            Ok(true) => {
                self.published_at = Some(std::time::Instant::now());
                self.stale = false;
            }
            // The plan is not recorded yet; the next batch retries.
            Ok(false) => {}
            // One failed update must not kill the watch, and must not turn
            // the poll cadence into an API hammer: back off a full interval.
            Err(error) => {
                crate::support::ui::warning(format!("progress publish failed: {error}"));
                self.published_at = Some(std::time::Instant::now());
            }
        }
    }

    fn publish(&self) -> Result<bool> {
        let Some(rendered) = load_running(self.watch.run_dir, &self.events)? else {
            return Ok(false);
        };
        if self.watch.comment {
            comment(
                self.client,
                &rendered,
                self.target,
                self.watch.reply_to,
                self.effects,
            )?;
        }
        if self.watch.check {
            check(self.client, &rendered, self.target, self.effects)?;
        }
        Ok(true)
    }
}

/// Append the full-detail projection to the step summary file.
pub fn step_summary(
    rendered: &Rendered,
    target: &Target,
    path: &Path,
    effects: crate::support::effects::Effects,
) -> Result<()> {
    use std::io::Write;
    let links = links(rendered, target);
    let text = markdown::truncate_sections(
        with_notice(
            markdown::step_summary(&rendered.report, &rendered.fragments, &links),
            target,
        )
        .into_string(),
        markdown::STEP_SUMMARY_BUDGET,
    );
    if effects.is_dry_run() {
        crate::support::ui::fact(
            "step summary",
            format!("skipped (dry run), {} bytes", text.len()),
        );
        return Ok(());
    }
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| crate::support::error::io(path, e))?;
    file.write_all(text.as_bytes())
        .map_err(|e| crate::support::error::io(path, e))
}
