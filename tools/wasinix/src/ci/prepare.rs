//! Turn a request into a run directory: resolved cases on disk, and the
//! run's own decisions recorded beside them. The directory holds the request
//! and preparation documents; everything else a run needs is a function of
//! them, and fragments accumulate from the tasks themselves.

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::ci::plan::{plan_of, Plan};
use crate::ci::types::{Override, Preparation, Request, ResolvedRequest, RevSource};
use crate::ci::workspace::write_materialization;
use crate::support::error::{request_error, Result};
use crate::support::git;

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
pub(crate) fn case_trusted(
    repo: &Path,
    source: &RevSource,
    overrides: &[Override],
    trusted_refs: &[String],
) -> Result<bool> {
    // An override injects a pin that is not part of any authoritative ref, so
    // the built tree is not reproducible from one and must not be signed, even
    // when the case's nominal source revision is itself trusted.
    if !overrides.is_empty() {
        return Ok(false);
    }
    for reference in trusted_refs {
        if git::is_ancestor(repo, source.rev.full(), reference)? {
            return Ok(true);
        }
    }
    Ok(false)
}

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
        match &self.request {
            Request::Diff(diff) => Some(diff.baseline.clone()),
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

fn reuse_baseline(request: &ResolvedRequest, run_dir: &Path, url: &str) -> Result<Vec<String>> {
    if crate::support::env::no_baseline_reuse()? {
        return Ok(Vec::new());
    }
    let Request::Diff(diff) = request else {
        return Ok(Vec::new());
    };
    let Some(case) = diff
        .cases
        .iter()
        .find(|c| c.case_id() == diff.baseline)
        .and_then(|case| case.as_build())
    else {
        return Ok(Vec::new());
    };
    if !crate::ci::baseline::is_reusable(case) {
        return Ok(Vec::new());
    }
    let Some(published) = crate::ci::baseline::fetch(case.source.rev.full(), url) else {
        return Ok(Vec::new());
    };
    if !crate::ci::baseline::covers(case, &published) {
        crate::support::ui::fact(
            "baseline reuse",
            "off (published run does not cover this selection)",
        );
        return Ok(Vec::new());
    }
    let target = case_dir(run_dir, case.case_id());
    if let Err(error) = crate::ci::baseline::materialize(&target, &published) {
        // A half-written case directory would read as a real result later.
        let _ = std::fs::remove_dir_all(&target);
        return Err(error);
    }
    crate::support::ui::fact("baseline reuse", format!("on ({})", case.source.rev));
    Ok(vec![case.case_id().to_string()])
}

pub fn prepare_all(
    repo: &Path,
    request: &ResolvedRequest,
    run_dir: &Path,
    trusted_refs: &[String],
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
    let reused = reuse_baseline(request, run_dir, &crate::ci::baseline::map_url_template())?;
    let cases = request.cases();
    let mut trusted = true;
    for case in &cases {
        trusted &= case_trusted(repo, case.source(), case.overrides(), trusted_refs)?;
    }

    let request_value = crate::support::schema::to_value(request)?;
    let mut prepared_cases = Vec::new();
    for (index, case) in cases.iter().enumerate() {
        let case_id = case.case_id().to_string();
        let mut case_value = match request {
            Request::Diff(_) => request_value["cases"][index].clone(),
            _ => request_value.clone(),
        };
        // The prepared document carries the case id so a phase task can find
        // itself in a request that did not name its cases.
        case_value["caseId"] = Value::String(case_id.clone());
        let prepared_dir = case_dir(run_dir, &case_id).join("prepared");
        crate::support::ui::fact(
            "materializing",
            format!("{case_id} at {}", case.source().rev.short()),
        );
        write_materialization(repo, *case, &case_value, &prepared_dir)?;
        // Trust ends at what a trusted ref contains: a working-tree diff on
        // top of a trusted rev is uncommitted content and must not sign.
        let patch = prepared_dir.join(crate::ci::workspace::PATCH_FILE);
        trusted &= std::fs::metadata(&patch)
            .map_err(|error| crate::support::error::io(&patch, error))?
            .len()
            == 0;
        prepared_cases.push(crate::support::json::read::<Value>(
            &prepared_dir.join("request.json"),
        )?);
    }

    let mut document = request_value;
    match request {
        Request::Diff(_) => {
            document["cases"] = Value::Array(prepared_cases);
        }
        _ => {
            document = prepared_cases.into_iter().next().unwrap();
        }
    }
    crate::support::json::write(&request_path(run_dir), &document)?;
    let preparation = Preparation { trusted, reused };
    crate::support::schema::write(&preparation_path(run_dir), &preparation)?;

    load(run_dir)
}
