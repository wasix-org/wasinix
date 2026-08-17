//! The markdown projections of one report: PR comment, check run, and step
//! summary, each under its own budget. Nothing here reads run state; it all
//! comes in as the folded report and its fragments. Every projection is
//! assembled from [`Markdown`] values, so text reaches a surface only
//! through the sanitizer for the context it lands in.

use std::collections::BTreeMap;

use crate::ci::compare::Comparison;
use crate::ci::events::Snapshot;
use crate::ci::facts::{Failure, FailureCause};
use crate::ci::report::{Conclusion, Fragment, FragmentData, Report};
use crate::github::sanitize::Markdown;
use crate::support::atoms::{Rev, TaskStatus};
use crate::support::format;

pub const CHECK_SUMMARY_BUDGET: usize = 8_000;
/// GitHub drops a step summary silently past ~1 MiB, so truncate under that
/// with our own note rather than let the platform cut it mid-content.
pub const STEP_SUMMARY_BUDGET: usize = 1_000_000;
pub const CHECK_TITLE_BUDGET: usize = 120;
const FAILURE_ROWS: usize = 20;
const PREEXISTING_ROWS: usize = 20;
const RECENT_FAILURES: usize = 5;

pub struct Links {
    /// The Actions run, which every report links.
    pub run_url: Option<String>,
    pub sha: Option<Rev>,
    /// Where per-job failure logs were published; rows link into it.
    pub log_base: Option<String>,
}

impl Links {
    fn heading_suffix(&self) -> Markdown {
        let mut parts = Vec::new();
        if let Some(url) = &self.run_url {
            parts.push(Markdown::link("run", url));
        }
        if let Some(sha) = &self.sha {
            parts.push(Markdown::code(sha.short()));
        }
        if parts.is_empty() {
            Markdown::new()
        } else {
            Markdown::constant(" · ").push(Markdown::join(parts, " · "))
        }
    }

    /// A link to the job's published log; nothing without one, since a link
    /// to the whole pipeline would only pretend to be specific.
    fn log_link(&self, job: &str) -> Markdown {
        match &self.log_base {
            Some(base) => Markdown::constant(" · ")
                .push(Markdown::cell_link("logs", &format!("{base}/{job}.txt"))),
            None => Markdown::new(),
        }
    }
}

fn glyph(status: TaskStatus) -> Markdown {
    Markdown::constant(match status {
        TaskStatus::Success => "✅",
        TaskStatus::Failure | TaskStatus::Cancelled => "❌",
        TaskStatus::Neutral => "⚠️",
        TaskStatus::Pending => "⏳",
        TaskStatus::Skipped => "⏭",
        TaskStatus::Deferred => "⏸",
    })
}

/// Every failure worth a row, flattened with its task. Transitive victims
/// stay out: their root (a direct failure or a dependency root cause)
/// carries the story, and [`blocked_count`] carries their number.
fn failures(report: &Report) -> Vec<(&str, &Failure)> {
    report
        .failures
        .iter()
        .flat_map(|(task, failures)| failures.iter().map(move |failure| (task.as_str(), failure)))
        .filter(|(_, failure)| failure.cause != FailureCause::Transitive)
        .collect()
}

/// Jobs that never ran because a failure below them ran first.
fn blocked_count(report: &Report) -> usize {
    report
        .failures
        .values()
        .flatten()
        .filter(|failure| failure.cause == FailureCause::Transitive)
        .count()
}

fn job_count(fragments: &BTreeMap<String, Fragment>) -> Option<usize> {
    fragments.values().find_map(|fragment| match &fragment.data {
        Some(FragmentData::Eval(summary)) => Some(summary.job_count),
        _ => None,
    })
}

fn build_seconds(fragments: &BTreeMap<String, Fragment>) -> f64 {
    fragments
        .values()
        .filter_map(|fragment| match &fragment.data {
            Some(FragmentData::Build(facts)) => Some(facts.build_seconds.values().sum::<f64>()),
            _ => None,
        })
        .sum()
}

fn failure_cause(failure: &Failure) -> Markdown {
    match &failure.message {
        Some(message) => {
            let first = message.lines().next().unwrap_or_default();
            Markdown::cell(&first.chars().take(120).collect::<String>())
        }
        None if !failure.jobs.is_empty() => Markdown::text(&format!(
            "dependency failure taking down {} jobs",
            failure.jobs.len()
        )),
        None => Markdown::constant("no build log was captured"),
    }
}

/// Numbers and other tool-computed text: nothing to sanitize, but it still
/// enters as a typed value.
fn plural(count: usize, noun: &str) -> Markdown {
    if count == 1 {
        Markdown::text(&format!("{count} {noun}"))
    } else {
        Markdown::text(&format!("{count} {noun}s"))
    }
}

/// `N jobs blocked behind these failures`, or nothing.
fn blocked_line(report: &Report) -> Markdown {
    let blocked = blocked_count(report);
    if blocked == 0 {
        return Markdown::new();
    }
    Markdown::concat([
        Markdown::constant("\n"),
        plural(blocked, "job"),
        Markdown::constant(" blocked behind these failures\n"),
    ])
}

fn failure_table(rows: &[(&str, &Failure)], links: &Links, cap: usize) -> Markdown {
    let mut table = Markdown::constant("| job | task | failure |\n|:--|:--|:--|\n");
    for (task, failure) in rows.iter().take(cap) {
        table = Markdown::concat([
            table,
            Markdown::constant("| "),
            Markdown::cell_code(failure.job.as_str()),
            Markdown::constant(" | "),
            Markdown::cell(task),
            Markdown::constant(" | "),
            failure_cause(failure),
            links.log_link(failure.job.as_str()),
            Markdown::constant(" |\n"),
        ]);
    }
    if rows.len() > cap {
        table = Markdown::concat([
            table,
            Markdown::constant("\nand "),
            Markdown::text(&(rows.len() - cap).to_string()),
            Markdown::constant(" more in the step summary\n"),
        ]);
    }
    table
}

/// The phase ladder: one line per case with the case named once, and the
/// run-level facts on a final line, all inside one small-print block.
fn ladder<'a>(
    tasks: impl IntoIterator<Item = &'a crate::ci::report::TaskView>,
    trailing: Vec<Markdown>,
) -> Markdown {
    let mut cases: Vec<(String, Vec<Markdown>)> = Vec::new();
    for task in tasks {
        let prefix = format!("{}: ", task.case);
        let label = task.label.strip_prefix(&prefix).unwrap_or(&task.label);
        let item = Markdown::concat([
            Markdown::text(label),
            Markdown::constant(" "),
            glyph(task.status),
        ]);
        match cases.iter_mut().find(|(case, _)| case == &task.case) {
            Some((_, items)) => items.push(item),
            None => cases.push((task.case.clone(), vec![item])),
        }
    }
    let mut lines: Vec<Markdown> = cases
        .into_iter()
        .map(|(case, items)| {
            Markdown::concat([
                Markdown::text(&case),
                Markdown::constant(": "),
                Markdown::join(items, " · "),
            ])
        })
        .collect();
    if !trailing.is_empty() {
        lines.push(Markdown::join(trailing, " · "));
    }
    Markdown::concat([
        Markdown::constant("<sub>"),
        Markdown::join(lines, "<br>"),
        Markdown::constant("</sub>\n"),
    ])
}

fn footer(report: &Report, fragments: &BTreeMap<String, Fragment>, links: &Links) -> Markdown {
    let mut trailing = Vec::new();
    if let Some(jobs) = job_count(fragments) {
        trailing.push(Markdown::text(&format!("{jobs} jobs")));
    }
    let seconds = build_seconds(fragments);
    if seconds > 0.0 {
        trailing.push(Markdown::text(&format!(
            "{} build time",
            format::duration(seconds)
        )));
    }
    if let Some(url) = &links.run_url {
        trailing.push(Markdown::html_link("full pipeline", url));
    }
    ladder(
        report
            .tasks
            .iter()
            .filter(|task| task.enabled && !task.headline.is_empty()),
        trailing,
    )
}

fn details(report: &Report) -> Markdown {
    let mut body = Markdown::new();
    if let Some(request) = &report.request {
        if let Ok(echo) = serde_json::to_string_pretty(request) {
            body = Markdown::concat([
                body,
                Markdown::constant("**Request**\n\n"),
                Markdown::fenced(&echo, "json"),
                Markdown::constant("\n"),
            ]);
        }
    }
    body = body.push(Markdown::constant(
        "**Pipeline**\n\n| task | status | result |\n|:--|:--:|:--|\n",
    ));
    for task in &report.tasks {
        body = Markdown::concat([
            body,
            Markdown::constant("| "),
            Markdown::cell(&task.label),
            Markdown::constant(" | "),
            glyph(task.status),
            Markdown::constant(" | "),
            Markdown::cell(&task.headline),
            Markdown::constant(" |\n"),
        ]);
    }
    for updates in report.version_updates.values() {
        if updates.is_empty() {
            continue;
        }
        body = Markdown::concat([
            body,
            Markdown::constant("\n**Downstream version changes ("),
            Markdown::text(&updates.len().to_string()),
            Markdown::constant(")**\n\n"),
        ]);
        for update in updates.iter().take(20) {
            body = Markdown::concat([
                body,
                Markdown::constant("- **"),
                Markdown::cell(&update.subject),
                Markdown::constant("** "),
                Markdown::cell(&update.before),
                Markdown::constant(" → "),
                Markdown::cell(&update.after),
                Markdown::constant("\n"),
            ]);
        }
        if updates.len() > 20 {
            body = Markdown::concat([
                body,
                Markdown::constant("- ... and "),
                Markdown::text(&(updates.len() - 20).to_string()),
                Markdown::constant(" more\n"),
            ]);
        }
    }
    Markdown::concat([
        Markdown::constant("<details><summary>Details</summary>\n\n"),
        body,
        Markdown::constant("\n</details>\n"),
    ])
}

/// The comparisons' summaries and lists, in the comment body proper: what a
/// diff changed is the comment's story, not a collapsed detail. Each half
/// renders as soon as the fold could derive it.
fn comparison_block(report: &Report) -> Markdown {
    Markdown::concat(
        report
            .comparisons
            .iter()
            .filter(|comparison| comparison.eval.is_some())
            .map(|comparison| comparison_lists(comparison).push(Markdown::constant("\n"))),
    )
}

const COMPARE_LIST_ROWS: usize = 250;

/// One collapsible job list, each row naming the version the job serves.
fn job_list(
    title: &'static str,
    jobs: &[crate::support::atoms::JobAddr],
    identities: &BTreeMap<crate::support::atoms::JobAddr, String>,
    open: bool,
) -> Markdown {
    if jobs.is_empty() {
        return Markdown::constant("");
    }
    let mut body = Markdown::concat([
        Markdown::constant("\n<details"),
        Markdown::constant(if open { " open" } else { "" }),
        Markdown::constant("><summary>"),
        Markdown::constant(title),
        Markdown::constant(" ("),
        Markdown::text(&jobs.len().to_string()),
        Markdown::constant(")</summary>\n\n"),
    ]);
    for job in jobs.iter().take(COMPARE_LIST_ROWS) {
        body = Markdown::concat([
            body,
            Markdown::constant("- "),
            Markdown::code(job.as_str()),
            match identities.get(job) {
                Some(identity) => {
                    Markdown::concat([Markdown::constant(" at "), Markdown::text(identity)])
                }
                None => Markdown::constant(""),
            },
            Markdown::constant("\n"),
        ]);
    }
    if jobs.len() > COMPARE_LIST_ROWS {
        body = Markdown::concat([
            body,
            Markdown::constant("- ... and "),
            Markdown::text(&(jobs.len() - COMPARE_LIST_ROWS).to_string()),
            Markdown::constant(" more\n"),
        ]);
    }
    body.push(Markdown::constant("\n</details>\n"))
}

/// The comparison's non-failure stories: what got fixed, rebuilt,
/// re-versioned, added, or removed. Failures render in the report body, not
/// here. The eval half is always present (the caller filters); the build
/// half renders once builds finished.
fn comparison_lists(comparison: &Comparison) -> Markdown {
    let Some(eval) = &comparison.eval else {
        return Markdown::new();
    };
    let mut body = Markdown::constant("**Comparison** · ");
    if let Some(builds) = &comparison.builds {
        body = Markdown::concat([
            body,
            Markdown::text(&builds.fixes.len().to_string()),
            Markdown::constant(" fixed · "),
        ]);
    }
    body = Markdown::concat([
        body,
        Markdown::text(&eval.rebuilt.len().to_string()),
        Markdown::constant(" rebuilt · "),
        Markdown::text(&eval.identity_transitions.len().to_string()),
        Markdown::constant(" version/rel changes · "),
        Markdown::text(&eval.added.len().to_string()),
        Markdown::constant(" added · "),
        Markdown::text(&eval.removed.len().to_string()),
        Markdown::constant(" removed"),
        Markdown::constant(if comparison.builds.is_none() {
            " · builds pending\n"
        } else {
            "\n"
        }),
    ]);
    body = body.push(job_list(
        "New evaluation failures",
        &eval.new_eval_errors,
        &eval.identities,
        true,
    ));
    if let Some(builds) = &comparison.builds {
        body = body.push(job_list(
            "Removed jobs that passed",
            &builds.dropped_successes,
            &eval.identities,
            true,
        ));
        body = body.push(job_list("Fixed", &builds.fixes, &eval.identities, false));
    }
    if !eval.identity_transitions.is_empty() {
        let mut section = Markdown::concat([
            Markdown::constant("\n<details><summary>Version or rel changed ("),
            Markdown::text(&eval.identity_transitions.len().to_string()),
            Markdown::constant(")</summary>\n\n"),
        ]);
        for transition in eval.identity_transitions.iter().take(COMPARE_LIST_ROWS) {
            section = Markdown::concat([
                section,
                Markdown::constant("- "),
                Markdown::code(transition),
                Markdown::constant("\n"),
            ]);
        }
        body = body.push(section.push(Markdown::constant("\n</details>\n")));
    }
    // A toolchain change rebuilds nearly everything, so the list carries no
    // signal at that size; the count does.
    if eval.selected_count > 0 && eval.rebuilt.len() > eval.selected_count / 2 {
        body = Markdown::concat([
            body,
            Markdown::constant("\nRebuilt "),
            Markdown::text(&eval.rebuilt.len().to_string()),
            Markdown::constant(" of "),
            Markdown::text(&eval.selected_count.to_string()),
            Markdown::constant(" jobs (toolchain-wide).\n"),
        ]);
    } else {
        body = body.push(job_list("Rebuilt", &eval.rebuilt, &eval.identities, false));
    }
    body = body.push(job_list("Added", &eval.added, &eval.identities, false));
    body = body.push(job_list("Removed", &eval.removed, &eval.identities, false));
    body
}

/// The report comment through its states: running, then one of the three
/// final skeletons. The surface registry applies the budget when it posts.
pub fn comment(
    report: &Report,
    fragments: &BTreeMap<String, Fragment>,
    snapshot: Option<&Snapshot>,
    links: &Links,
) -> Markdown {
    match report.conclusion {
        None => in_progress(report, snapshot, links),
        Some(Conclusion::Success) => green(report, fragments, links),
        Some(Conclusion::Failure) => failing(report, fragments, links),
        Some(Conclusion::Neutral) => neutral(report, fragments, links),
    }
}

fn green(report: &Report, fragments: &BTreeMap<String, Fragment>, links: &Links) -> Markdown {
    let jobs = match job_count(fragments) {
        Some(jobs) => Markdown::text(&format!("{jobs} jobs green")),
        None => Markdown::constant("green"),
    };
    Markdown::concat([
        Markdown::constant("### ✅ Wasinix CI · "),
        jobs,
        links.heading_suffix(),
        Markdown::constant("\n\n"),
        comparison_block(report),
        footer(report, fragments, links),
        Markdown::constant("\n"),
        details(report),
    ])
}

fn failing(report: &Report, fragments: &BTreeMap<String, Fragment>, links: &Links) -> Markdown {
    let all = failures(report);
    // In a diff, regressions are the story and shared failures are the
    // baseline's condition; in a build, every failure is new.
    let builds: Vec<&crate::ci::compare::BuildDiff> = report
        .comparisons
        .iter()
        .filter_map(|comparison| comparison.builds.as_ref())
        .collect();
    let (primary, preexisting, what) = if builds.is_empty() {
        let count = all.len();
        (all.clone(), Vec::new(), plural(count, "failure"))
    } else {
        let regressed: Vec<(&str, &Failure)> = all
            .iter()
            .filter(|(_, failure)| {
                builds.iter().any(|diff| {
                    diff.regressions.contains(&failure.job)
                        || diff.new_failures.contains(&failure.job)
                })
            })
            .cloned()
            .collect();
        let existing: Vec<(&str, &Failure)> = all
            .iter()
            .filter(|(_, failure)| {
                builds
                    .iter()
                    .any(|diff| diff.existing_failures.contains(&failure.job))
            })
            .cloned()
            .collect();
        let count: usize = report
            .comparisons
            .iter()
            .map(Comparison::regression_count)
            .sum();
        let what = plural(count, "failure").push(Markdown::constant(" new"));
        (regressed, existing, what)
    };
    // Failed gates without failure atoms (treefmt, a timed-out eval) still
    // deserve an honest count; a report with no failed tasks at all (a
    // synthesized terminal report for a lost or cancelled run) carries its
    // whole story in the title.
    let what = if primary.is_empty() {
        let failed_tasks = report
            .tasks
            .iter()
            .filter(|task| matches!(task.status, TaskStatus::Failure | TaskStatus::Cancelled))
            .count();
        if failed_tasks == 0 {
            Markdown::text(&report.title)
        } else {
            plural(failed_tasks, "failed task")
        }
    } else {
        what
    };
    let mut text = Markdown::concat([
        Markdown::constant("### ❌ Wasinix CI · "),
        what,
        links.heading_suffix(),
        Markdown::constant("\n\n"),
    ]);
    if primary.is_empty() {
        for task in &report.tasks {
            if matches!(task.status, TaskStatus::Failure | TaskStatus::Cancelled) {
                text = Markdown::concat([
                    text,
                    Markdown::constant("- "),
                    Markdown::cell(&task.label),
                    Markdown::constant(" · "),
                    Markdown::cell(&task.headline),
                    Markdown::constant("\n"),
                ]);
            }
        }
        text = text.push(Markdown::constant("\n"));
    } else {
        text = text.push(failure_table(&primary, links, FAILURE_ROWS));
        text = text.push(blocked_line(report));
        text = text.push(Markdown::constant("\n"));
    }
    if !preexisting.is_empty() {
        text = Markdown::concat([
            text,
            Markdown::constant("<details><summary>"),
            Markdown::text(&format!(
                "{} more failures also failing on the base ({})",
                preexisting.len().min(PREEXISTING_ROWS),
                preexisting.len()
            )),
            Markdown::constant("</summary>\n\n"),
            failure_table(&preexisting, links, PREEXISTING_ROWS),
            Markdown::constant("\n</details>\n\n"),
        ]);
    }
    Markdown::concat([
        text,
        comparison_block(report),
        footer(report, fragments, links),
        Markdown::constant("\n"),
        details(report),
    ])
}

fn neutral(report: &Report, fragments: &BTreeMap<String, Fragment>, links: &Links) -> Markdown {
    let mut text = Markdown::concat([
        Markdown::constant("### ⚠️ Wasinix CI could not compare · "),
        Markdown::text(&report.title),
        links.heading_suffix(),
        Markdown::constant("\n\n"),
        Markdown::constant(
            "> The base did not produce results to compare against. This is not caused by your change.\n\n",
        ),
    ]);
    let all = failures(report);
    if !all.is_empty() {
        text = Markdown::concat([
            text,
            Markdown::constant("<details open><summary>"),
            Markdown::text(&format!(
                "Failures on this branch, baseline unknown ({})",
                all.len()
            )),
            Markdown::constant("</summary>\n\n"),
            failure_table(&all, links, FAILURE_ROWS),
            blocked_line(report),
            Markdown::constant("\n</details>\n\n"),
        ]);
    }
    text.push(footer(report, fragments, links))
}

fn in_progress(report: &Report, snapshot: Option<&Snapshot>, links: &Links) -> Markdown {
    let counts = match snapshot {
        Some(snapshot) => {
            let mut parts = vec![Markdown::text(&format!(
                "{} jobs done",
                snapshot.completed_jobs
            ))];
            if snapshot.failed_jobs > 0 {
                parts.push(Markdown::text(&format!("{} failed", snapshot.failed_jobs)));
            }
            Markdown::constant(" · ").push(Markdown::join(parts, " · "))
        }
        None => Markdown::new(),
    };
    let mut text = Markdown::concat([
        Markdown::constant("### ⏳ Wasinix CI · building"),
        counts,
        links.heading_suffix(),
        Markdown::constant("\n\n"),
    ]);
    if let Some(snapshot) = snapshot {
        if !snapshot.recent_failures.is_empty() {
            let shown: Vec<Markdown> = snapshot
                .recent_failures
                .iter()
                .rev()
                .take(RECENT_FAILURES)
                .map(|job| Markdown::code(job.as_str()))
                .collect();
            text = Markdown::concat([
                text,
                Markdown::constant("Failed so far: "),
                Markdown::join(shown, ", "),
                Markdown::constant("\n\n"),
            ]);
        }
    }
    // The comment is edited in place, so absolute wall-clock tells a reader
    // whether the run is live in a way "building" alone cannot.
    let mut trailing = Vec::new();
    if let Some(at) = snapshot.and_then(|snapshot| snapshot.last_event_at) {
        trailing.push(Markdown::text(&format!(
            "updated {}",
            crate::support::time::wall_clock_utc(at)
        )));
    }
    Markdown::concat([
        text,
        comparison_block(report),
        ladder(
            report.tasks.iter().filter(|task| task.enabled),
            trailing,
        ),
    ])
}

pub struct Check {
    /// Plain text, not markdown: the checks API renders the title literally.
    pub title: String,
    pub summary: String,
    pub conclusion: Option<Conclusion>,
}

/// The check run: a short title naming failing jobs and a summary that
/// points, never a copy of the comment.
pub fn check(report: &Report, fragments: &BTreeMap<String, Fragment>, links: &Links) -> Check {
    let all = failures(report);
    let title = match report.conclusion {
        Some(Conclusion::Success) => report.title.clone(),
        _ if all.is_empty() => report.title.clone(),
        _ => {
            let mut title = format!("{}: ", report.title);
            for (index, (_, failure)) in all.iter().enumerate() {
                let name = failure.job.as_str();
                if index > 0 && title.len() + name.len() + 2 > CHECK_TITLE_BUDGET - 3 {
                    title += "...";
                    break;
                }
                if index > 0 {
                    title += ", ";
                }
                title += name;
            }
            title
        }
    };
    let mut summary = Markdown::new();
    if !all.is_empty() {
        summary = failure_table(&all, links, FAILURE_ROWS).push(Markdown::constant("\n"));
    }
    summary = summary.push(footer(report, fragments, links));
    Check {
        title: title.chars().take(CHECK_TITLE_BUDGET).collect(),
        summary: truncate_sections(summary.into_string(), CHECK_SUMMARY_BUDGET),
        conclusion: report.conclusion,
    }
}

/// The step summary: the overflow home, so it renders everything the other
/// projections cap.
pub fn step_summary(
    report: &Report,
    fragments: &BTreeMap<String, Fragment>,
    links: &Links,
) -> Markdown {
    let mut text = comment(report, fragments, None, links);
    let all = failures(report);
    if all.len() > FAILURE_ROWS {
        text = Markdown::concat([
            text,
            Markdown::constant("\n**All failures ("),
            Markdown::text(&all.len().to_string()),
            Markdown::constant(")**\n\n"),
            failure_table(&all, links, usize::MAX),
        ]);
    }
    for fragment in fragments.values() {
        if let Some(FragmentData::Log(excerpt)) = &fragment.data {
            if excerpt.lines.is_empty() {
                continue;
            }
            text = Markdown::concat([
                text,
                Markdown::constant("\n**"),
                Markdown::text(&fragment.label),
                Markdown::constant("**\n\n"),
                Markdown::fenced(&excerpt.lines.join("\n"), "text"),
            ]);
        }
    }
    text
}

/// The reply when a `/wasinix` command dies before it can publish a report:
/// the failure tail fenced so a PR-controlled log line cannot render as
/// markup, and the run link for the rest.
pub fn failure_reply(detail: &str, run_url: Option<&str>) -> Markdown {
    let detail = if detail.trim().is_empty() {
        "see the Actions run"
    } else {
        detail
    };
    let mut body = Markdown::concat([
        Markdown::constant("❌ `/wasinix` command failed:\n\n"),
        Markdown::fenced(detail, "text"),
    ]);
    if let Some(url) = run_url {
        body = Markdown::concat([
            body,
            Markdown::constant("\n"),
            Markdown::link("Actions run", url),
            Markdown::constant("\n"),
        ]);
    }
    body
}

/// Drop trailing `<details>` blocks whole until the text fits, and say what
/// was dropped; never cut mid-fence.
pub fn truncate_sections(text: String, budget: usize) -> String {
    if text.len() <= budget {
        return text;
    }
    let mut kept = text.as_str();
    let mut dropped = 0usize;
    while kept.len() > budget.saturating_sub(64) {
        let Some(at) = kept.rfind("\n<details") else {
            break;
        };
        kept = kept[..at].trim_end();
        dropped += 1;
    }
    let mut result = kept.to_string();
    if dropped > 0 {
        result += &format!("\n\n{dropped} detail sections moved to the step summary\n");
    }
    if result.len() > budget {
        // No details left to drop: keep whole lines from the top.
        let mut cut = budget.saturating_sub(64);
        while cut > 0 && !result.is_char_boundary(cut) {
            cut -= 1;
        }
        let head = match result[..cut].rfind('\n') {
            Some(line_end) => &result[..line_end],
            None => &result[..cut],
        };
        result = format!("{head}\n\ntruncated; the step summary has the rest\n");
    }
    result
}
