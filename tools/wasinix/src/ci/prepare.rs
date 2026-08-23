//! Turn a request into a run directory: resolved cases on disk, and the
//! run's own decisions recorded beside them. The directory holds the request
//! and preparation documents; everything else a run needs is a function of
//! them, and fragments accumulate from the tasks themselves.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::ci::plan::{Plan, plan_of};
use crate::ci::types::{Preparation, RequestAction, ResolvedRequest};
use crate::ci::workspace::write_materialization;
use crate::support::error::{Result, request_error};

// The run directory's layout, stated here rather than by each module that
// reaches into it.
pub fn case_dir(run_dir: &Path, case_id: &str) -> PathBuf {
    cases_dir(run_dir).join(case_id)
}

pub fn fragments_dir(run_dir: &Path) -> PathBuf {
    run_dir.join("fragments")
}

pub fn report_dir(run_dir: &Path) -> PathBuf {
    run_dir.join("report")
}

pub fn request_path(run_dir: &Path) -> PathBuf {
    run_dir.join("request.json")
}

pub fn cases_dir(run_dir: &Path) -> PathBuf {
    run_dir.join("cases")
}

pub fn report_path(run_dir: &Path) -> PathBuf {
    report_dir(run_dir).join("report.json")
}

// The per-case layout, over a `case_dir` result.
pub fn maps_dir(case: &Path) -> PathBuf {
    case.join("maps")
}

pub fn eval_map_path(case: &Path) -> PathBuf {
    maps_dir(case).join("eval-map.json")
}

pub fn eval_jobs_path(case: &Path) -> PathBuf {
    maps_dir(case).join("eval-jobs.jsonl")
}

pub fn status_path(case: &Path) -> PathBuf {
    case.join("status.json")
}

pub fn junit_dir(case: &Path) -> PathBuf {
    case.join("junit")
}

pub fn logs_dir(case: &Path) -> PathBuf {
    case.join("logs")
}

pub fn preparation_path(run_dir: &Path) -> PathBuf {
    run_dir.join("preparation.json")
}

/// Whether a case builds code already contained in an authoritative ref. An
/// empty ref list denies trust, which is what a cross-repository command
/// should pass; a git failure is an error, since trust gates cache signing.
/// The run's state as `prepare` left it.
pub struct Loaded {
    pub request: ResolvedRequest,
    pub preparation: Preparation,
    pub request_id: String,
}

impl Loaded {
    pub fn plan(&self) -> Plan {
        plan_of(
            &self.request,
            Some(&self.request_id),
            &self.preparation.reused,
        )
    }

    pub fn baseline_case(&self) -> Option<String> {
        match &self.request.action {
            RequestAction::Diff(diff) => Some(diff.baseline.clone()),
            _ => None,
        }
    }
}

/// Read back what `prepare` wrote. Tasks take a run directory rather than a
/// document path: there is one document, and naming it again is only a way to
/// name the wrong one.
pub fn load(run_dir: &Path) -> Result<Loaded> {
    let value: Value = crate::support::json::read(&request_path(run_dir))?;
    let request_id = crate::ci::normalize::request_id(&value);
    let request: ResolvedRequest =
        crate::support::schema::from_value(value, &request_path(run_dir).display().to_string())?;
    let preparation: Preparation = crate::support::schema::read(&preparation_path(run_dir))?;
    Ok(Loaded {
        request,
        preparation,
        request_id,
    })
}

/// Adopt a published evaluation for one case when its materialized tree has
/// one. The tree is the honest key (patches and overrides produce their own),
/// so any case qualifies; coverage still has to include the selection.
enum Reuse {
    Reused,
    Missing(String),
}

impl Reuse {
    fn reused(&self) -> bool {
        matches!(self, Reuse::Reused)
    }

    fn headline(&self) -> String {
        match self {
            Reuse::Reused => "published evaluation reused".to_string(),
            Reuse::Missing(reason) => format!("not reused: {reason}"),
        }
    }
}

fn reuse_case(
    case: &crate::ci::types::Build<crate::ci::types::RevSource>,
    tree: &str,
    target: &Path,
    template: &str,
    baseline: bool,
) -> Result<Reuse> {
    let published = match crate::ci::baseline::fetch(tree, template) {
        crate::ci::baseline::Fetch::Found(published) => published,
        crate::ci::baseline::Fetch::Missing(reason) => return Ok(Reuse::Missing(reason)),
    };
    if !crate::ci::baseline::covers(case, &published) {
        return Ok(Reuse::Missing(
            "published run does not cover this selection".to_string(),
        ));
    }
    // A baseline is the status quo, failures included. Anything else is
    // being tested: adopting a red map would make one flaky failure stick to
    // its tree forever, so a re-run gets to rebuild.
    if !baseline
        && published
            .status
            .iter()
            .flatten()
            .any(|(_, status)| *status != crate::support::atoms::JobStatus::Success)
    {
        return Ok(Reuse::Missing(
            "published run has failures; rebuilding".to_string(),
        ));
    }
    if let Err(error) = crate::ci::baseline::materialize(target, &published) {
        // A half-written case directory would read as a real result later.
        let _ = std::fs::remove_dir_all(maps_dir(target));
        let _ = std::fs::remove_file(status_path(target));
        return Err(error);
    }
    Ok(Reuse::Reused)
}

pub fn prepare_all(repo: &Path, request: &ResolvedRequest, run_dir: &Path) -> Result<Loaded> {
    prepare_all_with(
        repo,
        request,
        run_dir,
        &crate::ci::baseline::map_url_template(),
    )
}

/// [`prepare_all`] against an explicit map location; the tests point it at a
/// directory of published maps.
pub fn prepare_all_with(
    repo: &Path,
    request: &ResolvedRequest,
    run_dir: &Path,
    map_template: &str,
) -> Result<Loaded> {
    if request_path(run_dir).exists()
        || cases_dir(run_dir).exists()
        || fragments_dir(run_dir).exists()
    {
        return request_error(format!(
            "run directory {} already contains prepared state",
            run_dir.display()
        ));
    }
    crate::support::fs::create_dir_all(run_dir)?;
    let mut tracker = crate::ci::events::Tracker::new(run_dir)?;
    let cases = request.cases();
    let mut reused: Vec<String> = Vec::new();
    let reuse_baselines = !crate::support::env::no_baseline_reuse()?;

    let request_value = crate::support::schema::to_value(request)?;
    let mut prepared_cases = Vec::new();
    for (index, case) in cases.iter().enumerate() {
        let case_id = case.case_id().to_string();
        let mut case_value = match &request.action {
            RequestAction::Diff(_) => request_value["cases"][index].clone(),
            _ => request_value.clone(),
        };
        // The prepared document carries the case id so a phase task can find
        // itself in a request that did not name its cases.
        case_value["caseId"] = Value::String(case_id.clone());
        let prepared_dir = case_dir(run_dir, &case_id).join("prepared");
        let (manifest, prepared_case) = tracker.phase(
            format!("prepare.{case_id}.materialize"),
            format!("{case_id}: Materializing {}", case.source().rev.short()),
            || {
                let manifest = write_materialization(repo, *case, &case_value, &prepared_dir)?;
                let prepared_case =
                    crate::support::json::read::<Value>(&prepared_dir.join("request.json"))?;
                Ok((manifest, prepared_case))
            },
            |_| "source materialized".to_string(),
        )?;
        prepared_cases.push(prepared_case);
        if reuse_baselines {
            if let crate::ci::types::CaseRef::Build(build) = case {
                let baseline = match &request.action {
                    RequestAction::Diff(diff) => diff.baseline == case_id,
                    _ => false,
                };
                let reuse = tracker.phase(
                    format!("prepare.{case_id}.baseline"),
                    format!("{case_id}: Baseline reuse"),
                    || {
                        reuse_case(
                            build,
                            &manifest.tree,
                            &case_dir(run_dir, &case_id),
                            map_template,
                            baseline,
                        )
                    },
                    Reuse::headline,
                )?;
                if reuse.reused() {
                    reused.push(case_id);
                }
            }
        }
    }

    let mut document = request_value;
    match &request.action {
        RequestAction::Diff(_) => {
            document["cases"] = Value::Array(prepared_cases);
        }
        _ => {
            document = prepared_cases.into_iter().next().unwrap();
        }
    }
    let preparation = Preparation { reused };
    tracker.phase(
        "prepare.plan",
        "Generating the run plan",
        || {
            crate::support::json::write(&request_path(run_dir), &document)?;
            crate::support::schema::write(&preparation_path(run_dir), &preparation)?;
            load(run_dir)
        },
        |loaded| format!("{} tasks planned", loaded.plan().tasks.len()),
    )
}
