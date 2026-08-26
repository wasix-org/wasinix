//! Publish one run's report to its GitHub surfaces: the PR comment, the
//! check run, and the step summary, all rendered from the same report.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::json;

use crate::ci::events::Snapshot;
use crate::ci::report::{Conclusion, Fragment, Report};
use crate::github::client::Client;
use crate::github::markdown::{self, FailureLogKey, Links};
use crate::github::surfaces::{Registry, Surface};
use crate::support::capability::Capability;
use crate::support::error::Result;

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
    pub failure_logs: BTreeMap<FailureLogKey, String>,
}

const UNTRUSTED_NOTICE: &str = "> [!NOTE]\n> This result was produced by this \
    pull request's own code and is advisory; it is not an authoritative CI \
    verdict.\n\n";

/// Every published body passes here, so an untrusted report cannot reach any
/// surface without its advisory notice.
fn with_notice(
    body: crate::github::sanitize::Markdown,
    target: &Target,
) -> crate::github::sanitize::Markdown {
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
    pub bisect: Option<crate::nix::bisect::Report>,
}

fn load_bisect(run_dir: &Path) -> Result<Option<crate::nix::bisect::Report>> {
    let path = run_dir.join("bisect").join(crate::nix::bisect::REPORT_FILE);
    if !path.exists() {
        return Ok(None);
    }
    crate::support::json::read(&path).map(Some)
}

pub fn load(run_dir: &Path) -> Result<Rendered> {
    let report_path = crate::ci::prepare::report_path(run_dir);
    let mut synthesized: Option<crate::ci::report::Fragment> = None;
    let mut report = if report_path.exists() {
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
        let tail = crate::runs::log_tail(run_dir, 1500);
        if let Some(tail) = &tail {
            synthesized = Some(crate::ci::report::run_log_fragment(tail));
        }
        crate::ci::report::from_run_state(&run, tail.as_deref())
    };
    report.command = origin_command(run_dir);
    report.attach_run_data(run_dir)?;
    let mut fragments =
        crate::ci::report::fragments_under(&crate::ci::prepare::fragments_dir(run_dir))?;
    if let Some(fragment) = synthesized {
        fragments.insert(fragment.task_id.clone(), fragment);
    }
    let snapshot = crate::ci::events::read_snapshot(run_dir).ok();
    Ok(Rendered {
        report,
        fragments,
        snapshot,
        bisect: load_bisect(run_dir)?,
    })
}

/// The command a comment asked for, recorded by `ci command` before it
/// plans anything. A run that died in materialization has no request to
/// echo, and the command is what a reader needs to see.
fn origin_command(run_dir: &Path) -> Option<String> {
    let document: crate::ci::origin::Command =
        crate::support::schema::read(&run_dir.join(crate::runs::ORIGIN_FILE)).ok()?;
    Some(document.command)
}

/// [`load`] for a run still executing: the same fold over the fragments
/// written so far, concluding nothing. None until the run has recorded its
/// plan, which is the earliest moment the surfaces have something to say.
pub(crate) fn load_running(
    run_dir: &Path,
    events: &[crate::ci::events::Event],
) -> Result<Option<Rendered>> {
    if !crate::ci::prepare::preparation_path(run_dir).exists() {
        // No plan yet, but the run is doing something the pull request
        // should see: materializing a worktree and resolving overrides runs
        // for minutes before the first task opens.
        let tail = crate::runs::log_tail(run_dir, 4_000);
        let snapshot = (!events.is_empty()).then(|| crate::ci::events::fold_snapshot(events));
        let mut report = crate::ci::report::Report {
            command: origin_command(run_dir),
            ..crate::ci::report::starting(tail.as_deref())
        };
        if let Some(snapshot) = &snapshot {
            report.started_at = snapshot.started_at;
            if let Some(phase) = snapshot.phases.last() {
                report.title = phase
                    .headline
                    .clone()
                    .unwrap_or_else(|| phase.label.clone());
            }
        }
        report.attach_run_data(run_dir)?;
        return Ok(Some(Rendered {
            report,
            fragments: BTreeMap::new(),
            snapshot,
            bisect: load_bisect(run_dir)?,
        }));
    }
    let loaded = crate::ci::prepare::load(run_dir)?;
    let fragments =
        crate::ci::report::fragments_under(&crate::ci::prepare::fragments_dir(run_dir))?;
    let snapshot = crate::ci::events::fold_snapshot(events);
    let mut report = crate::ci::report::fold(
        &loaded.plan(),
        &fragments,
        crate::ci::report::FoldContext {
            baseline_case: loaded.baseline_case(),
            finished: false,
            started_at: snapshot.started_at,
            finished_at: None,
            request: Some(loaded.request.clone()),
            reused_cases: loaded.preparation.reused.len(),
            comparisons: crate::ci::compare::project(run_dir, &loaded.request, false)?,
        },
    );
    report.attach_run_data(run_dir)?;
    Ok(Some(Rendered {
        report: crate::ci::report::Report {
            command: origin_command(run_dir),
            ..report
        },
        fragments,
        snapshot: Some(snapshot),
        bisect: load_bisect(run_dir)?,
    }))
}

fn links(_rendered: &Rendered, target: &Target, reply_to: Option<u64>) -> Links {
    Links {
        run_url: target.run_url.clone(),
        sha: target
            .head_sha
            .as_deref()
            .and_then(|sha| crate::support::atoms::Rev::parse(sha).ok()),
        failure_logs: target.failure_logs.clone(),
        origin: match (reply_to, target.pull_request) {
            (Some(comment_id), Some(pull_request)) => {
                Some(crate::github::surfaces::origin_comment_url(
                    &target.repository,
                    pull_request,
                    comment_id,
                ))
            }
            _ => None,
        },
        rendered_at: crate::support::time::unix_secs(),
    }
}

fn failure_log_name(key: &FailureLogKey) -> String {
    use sha2::{Digest, Sha256};

    let mut digest = Sha256::new();
    digest.update(key.task.as_bytes());
    digest.update([0]);
    digest.update(key.archive.as_bytes());
    let digest = format!("{:x}", digest.finalize());
    format!("{}.txt", &digest[..24])
}

#[cfg(test)]
pub(crate) fn stage_failure_logs(
    run_dir: &Path,
    report: &Report,
    sha: &str,
    destination: &Path,
) -> Result<BTreeMap<FailureLogKey, String>> {
    stage_failure_map(run_dir, &report.failures, sha, destination)
}

fn stage_failure_map(
    run_dir: &Path,
    failures: &BTreeMap<String, Vec<crate::ci::facts::Failure>>,
    namespace: &str,
    destination: &Path,
) -> Result<BTreeMap<FailureLogKey, String>> {
    let base = format!(
        "{}/logs/{namespace}",
        crate::support::nix::CACHE_SUBSTITUTER
    );
    let mut published = BTreeMap::new();
    for (task, failures) in failures {
        for failure in failures {
            let Some(log) = &failure.log else {
                continue;
            };
            let key = FailureLogKey::new(task, log.path.as_str());
            if published.contains_key(&key) {
                continue;
            }
            let logs_dir = crate::ci::prepare::build_logs_dir(run_dir, task)?;
            let name = failure_log_name(&key);
            let text = crate::ci::facts::logs::read_archived(&logs_dir, log, usize::MAX)?;
            crate::support::fs::write(&destination.join(&name), text.as_bytes())?;
            published.insert(key, format!("{base}/{name}"));
        }
    }
    Ok(published)
}

/// Upload the archived log bound to each rendered failure and return its URL.
pub fn publish_failure_logs(
    run_dir: &Path,
    rendered: &Rendered,
    sha: &str,
    effects: crate::support::effects::Effects,
) -> Result<BTreeMap<FailureLogKey, String>> {
    if let Some(report) = &rendered.bisect {
        let Some((run_dir, failures, namespace)) = bisect_failure_source(report, sha) else {
            return Ok(BTreeMap::new());
        };
        return publish_failure_map(run_dir, failures, &namespace, effects);
    }
    publish_failure_map(run_dir, &rendered.report.failures, sha, effects)
}

fn publish_failure_map(
    run_dir: &Path,
    failures: &BTreeMap<String, Vec<crate::ci::facts::Failure>>,
    namespace: &str,
    effects: crate::support::effects::Effects,
) -> Result<BTreeMap<FailureLogKey, String>> {
    let scratch = crate::support::fs::Scratch::create("wasinix-failure-logs")?;
    let published = stage_failure_map(run_dir, failures, namespace, scratch.path())?;
    if published.is_empty() {
        return Ok(published);
    }
    let count = published.len();
    if effects.is_dry_run() {
        crate::support::ui::fact("failure logs", format!("skipped (dry run), {count} logs"));
        return Ok(published);
    }
    let mut cmd = Capability::Aws.command()?;
    cmd.args(["s3", "cp", "--no-progress", "--recursive"])
        .arg(scratch.path())
        .arg(format!(
            "s3://{}/logs/{namespace}",
            crate::support::nix::CACHE_BUCKET
        ))
        .args(["--content-type", "text/plain; charset=utf-8"])
        .args(["--endpoint-url", crate::support::nix::CACHE_ENDPOINT]);
    crate::support::tools::checked_output(&mut cmd, "publishing failure logs")?;
    crate::support::ui::fact(
        "failure logs",
        format!(
            "{count} at {}/logs/{namespace}",
            crate::support::nix::CACHE_SUBSTITUTER
        ),
    );
    Ok(published)
}

fn bisect_log_namespace(
    report: &crate::nix::bisect::Report,
    boundary: &crate::nix::bisect::TestResult,
    sha: &str,
) -> String {
    use sha2::{Digest, Sha256};

    let mut digest = Sha256::new();
    for part in std::iter::once(report.target.as_str())
        .chain(std::iter::once(boundary.rev.as_str()))
        .chain(report.command.iter().map(String::as_str))
    {
        digest.update(part.as_bytes());
        digest.update([0]);
    }
    let digest = format!("{:x}", digest.finalize());
    format!("{sha}/bisect-{}", &digest[..24])
}

fn bisect_failure_source<'a>(
    report: &'a crate::nix::bisect::Report,
    sha: &str,
) -> Option<(
    &'a Path,
    &'a BTreeMap<String, Vec<crate::ci::facts::Failure>>,
    String,
)> {
    let boundary = report.boundary()?;
    let evidence = boundary.evidence.as_ref()?;
    Some((
        &boundary.run_dir,
        &evidence.failures,
        bisect_log_namespace(report, boundary, sha),
    ))
}

#[cfg(test)]
pub(crate) fn stage_bisect_failure_logs(
    report: &crate::nix::bisect::Report,
    sha: &str,
    destination: &Path,
) -> Result<BTreeMap<FailureLogKey, String>> {
    let Some((run_dir, failures, namespace)) = bisect_failure_source(report, sha) else {
        return Ok(BTreeMap::new());
    };
    stage_failure_map(run_dir, failures, &namespace, destination)
}

pub(crate) fn comment_markdown(
    rendered: &Rendered,
    target: &Target,
    reply_to: Option<u64>,
) -> Result<crate::github::sanitize::Markdown> {
    let links = links(rendered, target, reply_to);
    let bisect = if let Some(bisect) = &rendered.bisect {
        let origin = links.origin.as_deref().ok_or_else(|| {
            crate::support::error::Error::Request(
                "publishing a bisect report needs --reply-to".into(),
            )
        })?;
        let bisect_finished = bisect.first_bad.is_some() || bisect.revisions_left.is_some();
        let (reply, updated_at) = match rendered.report.conclusion {
            None if !bisect_finished => (
                markdown::bisect_progress(bisect.tests.len()),
                Some(
                    rendered
                        .snapshot
                        .as_ref()
                        .and_then(|snapshot| snapshot.last_event_at)
                        .unwrap_or(links.rendered_at),
                ),
            ),
            None | Some(Conclusion::Success) => {
                (markdown::bisect_reply(bisect, None, &links), None)
            }
            Some(_) => {
                let failure = rendered
                    .report
                    .diagnostics
                    .first()
                    .map(|diagnostic| diagnostic.message.as_str())
                    .unwrap_or(&rendered.report.title);
                (markdown::bisect_reply(bisect, Some(failure), &links), None)
            }
        };
        Some(markdown::command_reply(
            reply,
            rendered.report.command.as_deref(),
            origin,
            updated_at,
            links.run_url.as_deref(),
            links.sha.as_ref(),
        ))
    } else {
        None
    };
    Ok(with_notice(
        bisect.unwrap_or_else(|| {
            markdown::comment(
                &rendered.report,
                &rendered.fragments,
                rendered.snapshot.as_ref(),
                &links,
            )
        }),
        target,
    ))
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
    let body = comment_markdown(rendered, target, reply_to)?;
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

pub(crate) fn check_run_id(response: &serde_json::Value, run_url: &str) -> Option<u64> {
    response["check_runs"]
        .as_array()?
        .iter()
        .filter(|run| {
            run["external_id"].as_str() == Some(run_url)
                || run["details_url"].as_str() == Some(run_url)
        })
        .filter_map(|run| run["id"].as_u64())
        .max()
}

/// Create or complete this workflow run's "Wasinix CI" check. A dry run
/// renders the projection and stops before touching the API.
pub fn check(
    client: &Client,
    rendered: &Rendered,
    target: &Target,
    effects: crate::support::effects::Effects,
) -> Result<()> {
    let head_sha = target.head_sha.as_deref().ok_or_else(|| {
        crate::support::error::Error::Request("publishing a check needs the head sha".into())
    })?;
    let run_url = target.run_url.as_deref().ok_or_else(|| {
        crate::support::error::Error::Request(
            "publishing a check needs --run-url to identify the workflow run".into(),
        )
    })?;
    let links = links(rendered, target, None);
    let projected = markdown::check(&rendered.report, &rendered.fragments, &links);
    let mut body = json!({
        "name": "Wasinix CI",
        "head_sha": head_sha,
        "external_id": run_url,
        "details_url": run_url,
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
            body["conclusion"] = conclusion
                .as_github(rendered.report.blocked_policy())
                .into();
        }
        None => {
            body["status"] = "in_progress".into();
        }
    }
    if effects.is_dry_run() {
        crate::support::ui::fact("check run", "skipped (dry run)");
        return Ok(());
    }
    // A commit can be built by multiple workflow runs. Their checks share a
    // name and sha, so only the external identity distinguishes their state.
    let response = client.get(&format!(
        "repos/{}/commits/{head_sha}/check-runs?check_name=Wasinix%20CI",
        target.repository
    ))?;
    let existing = check_run_id(&response, run_url);
    match existing {
        Some(id) => client.patch(
            &format!("repos/{}/check-runs/{id}", target.repository),
            &body,
        )?,
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
    reply_to: Option<u64>,
    path: &Path,
    effects: crate::support::effects::Effects,
) -> Result<()> {
    let links = links(rendered, target, None);
    let body = if rendered.bisect.is_some() {
        comment_markdown(rendered, target, reply_to)?
    } else {
        with_notice(
            markdown::step_summary(&rendered.report, &rendered.fragments, &links),
            target,
        )
    };
    let text = markdown::truncate_sections(body.into_string(), markdown::STEP_SUMMARY_BUDGET);
    if effects.is_dry_run() {
        crate::support::ui::fact(
            "step summary",
            format!("skipped (dry run), {} bytes", text.len()),
        );
        return Ok(());
    }
    crate::support::fs::append(path, text.as_bytes())
}
