//! Reuse a published main-branch evaluation as a diff's baseline side. The
//! baseline is usually a revision main already built; fetching that run's
//! evaluation and per-job status costs one request where rebuilding it costs
//! a full evaluation and, on a toolchain change, a full build.

use std::path::Path;

use crate::ci::compare::JobStatuses;
use crate::ci::evalmap::{EvalMap, StatusMap};
use crate::ci::types::{Build, RevSource};
use crate::support::atoms::JobAddr;
use crate::support::capability::Capability;
use crate::support::error::Result;

/// The template the production reuse path fetches; tests substitute a local
/// server's.
pub fn map_url_template() -> String {
    format!(
        "{}/eval-maps/{{tree}}.json",
        crate::support::nix::CACHE_SUBSTITUTER
    )
}

pub enum Fetch {
    Found(EvalMap),
    Missing(String),
}

/// Fetch the map published for a git tree object id. The tree determines the
/// evaluation, so the key verifies itself: no run can publish under a tree
/// it did not build. A template without a scheme is read from the
/// filesystem, which the tests use.
pub fn fetch(tree: &str, url_template: &str) -> Fetch {
    let url = url_template.replace("{tree}", tree);
    let value = if url.contains("://") {
        crate::support::http::get_json(&url)
    } else {
        crate::support::json::read(Path::new(&url))
    };
    let value = match value {
        Ok(value) => value,
        Err(error) => {
            return Fetch::Missing(error.to_string());
        }
    };
    let published: EvalMap = match crate::support::schema::from_value(value, &url) {
        Ok(published) => published,
        Err(error) => {
            return Fetch::Missing(error.to_string());
        }
    };
    // Coverage makes a partial or interrupted build distinguishable from a
    // complete baseline. A status map alone cannot: it may contain just the
    // jobs that happened to finish before cancellation.
    if published.status.is_none() || published.coverage.is_empty() {
        return Fetch::Missing("published map carries no status coverage".into());
    }
    Fetch::Found(published)
}

/// Lay a fetched baseline out as if its tasks had run in this run directory.
pub fn materialize(paths: &Path, published: &EvalMap) -> Result<()> {
    let mut mapping = published.clone();
    let statuses = JobStatuses {
        statuses: mapping.status.take().unwrap_or_default(),
    };
    mapping.coverage = Vec::new();
    crate::support::schema::write(&crate::ci::prepare::eval_map_path(paths), &mapping)?;
    crate::support::schema::write(&crate::ci::prepare::status_path(paths), &statuses)?;
    mapping.record_completions();
    Ok(())
}

/// Evaluable jobs this request promises to build. Evaluation errors are kept
/// in the map and compared separately, so they do not need a build status.
pub fn expected_jobs(case: &Build<RevSource>, mapping: &EvalMap) -> Result<Vec<String>> {
    Ok(crate::ci::compare::selected(case, mapping)?
        .into_iter()
        .filter(|job| mapping.jobs.contains_key(job.as_str()))
        .collect())
}

pub fn missing_status(
    case: &Build<RevSource>,
    mapping: &EvalMap,
    status: &StatusMap,
) -> Result<Vec<String>> {
    Ok(expected_jobs(case, mapping)?
        .into_iter()
        .filter(|job| !status.contains_key(job.as_str()))
        .collect())
}

pub fn covers(case: &Build<RevSource>, published: &EvalMap) -> bool {
    let covered: std::collections::BTreeSet<&str> =
        published.coverage.iter().map(JobAddr::as_str).collect();
    expected_jobs(case, published)
        .map(|jobs| jobs.iter().all(|job| covered.contains(job.as_str())))
        .unwrap_or(false)
}

/// Publish a run's build case for later reuse. A map whose build failed is
/// still a valid baseline: the statuses are exactly what a comparison needs.
pub fn publish_from_run(
    run_dir: &Path,
    case_id: &str,
    effects: crate::support::effects::Effects,
) -> Result<()> {
    let paths = crate::ci::prepare::case_dir(run_dir, case_id);
    let eval_map = crate::ci::prepare::eval_map_path(&paths);
    if !eval_map.exists() {
        crate::support::ui::fact(
            "baseline",
            format!("skipped ({case_id}: evaluation did not produce a map)"),
        );
        return Ok(());
    }
    // The key is the materialized tree's object id, recorded at prepare
    // time, so a patched or overridden run publishes under its own tree and
    // can never claim a commit's.
    let manifest: crate::ci::workspace::Materialization =
        crate::support::schema::read(&paths.join("prepared/materialization.json"))?;
    let mapping: EvalMap = crate::support::schema::read(&eval_map)?;
    let rev = mapping.rev.clone().ok_or_else(|| {
        crate::support::error::Error::Failure(
            "the eval map names no revision to publish under".into(),
        )
    })?;
    let status = crate::ci::compare::case_status(&paths);
    if status.is_empty() {
        // A cancelled or eval-only case has nothing usable: a baseline
        // without coverage would read as complete and never be.
        crate::support::ui::fact(
            "baseline",
            format!("skipped ({case_id}: no build statuses)"),
        );
        return Ok(());
    }
    let mut junits: Vec<std::path::PathBuf> =
        std::fs::read_dir(crate::ci::prepare::junit_dir(&paths))
            .map(|entries| {
                entries
                    .flatten()
                    .map(|entry| entry.path())
                    .filter(|path| path.extension().is_some_and(|ext| ext == "xml"))
                    .collect()
            })
            .unwrap_or_default();
    junits.sort();
    let coverage: Vec<JobAddr> = status.keys().cloned().collect();
    let document = publish_document(
        &mapping,
        &status,
        &coverage,
        &crate::ci::facts::metrics(&junits).build_seconds,
        &task_timings(run_dir, case_id),
    );
    let scratch = crate::support::fs::Scratch::create("wasinix-baseline")?;
    let file = scratch.path().join("eval-map.json");
    crate::support::schema::write(&file, &document)?;
    if effects.is_dry_run() {
        crate::support::ui::fact(
            "baseline",
            format!("skipped (dry run), tree {} of rev {rev}", manifest.tree),
        );
        return Ok(());
    }
    let mut cmd = Capability::Aws.command()?;
    cmd.args(["s3", "cp", "--no-progress"])
        .arg(&file)
        .arg(format!(
            "s3://{}/eval-maps/{}.json",
            crate::support::nix::CACHE_BUCKET,
            manifest.tree
        ))
        .args(["--endpoint-url", crate::support::nix::CACHE_ENDPOINT]);
    crate::support::tools::checked_output(&mut cmd, "publishing the baseline map")?;
    crate::support::ui::fact(
        "baseline published",
        format!("tree {} of rev {rev}", manifest.tree),
    );
    Ok(())
}

/// This case's task wall times, from the fragments the run left behind. A
/// task that never finished has no fragment and no time to report.
fn task_timings(run_dir: &Path, case_id: &str) -> Vec<crate::ci::evalmap::TaskTiming> {
    let fragments = crate::ci::report::fragments_under(&crate::ci::prepare::fragments_dir(run_dir))
        .unwrap_or_default();
    fragments
        .values()
        .filter(|fragment| fragment.task_id.starts_with(&format!("{case_id}.")))
        .filter_map(|fragment| {
            Some(crate::ci::evalmap::TaskTiming {
                task_id: fragment.task_id.clone(),
                label: fragment.label.clone(),
                seconds: fragment.elapsed_seconds?.0,
            })
        })
        .collect()
}

/// The document a completed build publishes for later reuse: its eval map
/// with status, coverage, and build and task times folded in.
pub fn publish_document(
    mapping: &EvalMap,
    status: &StatusMap,
    coverage: &[JobAddr],
    build_seconds: &std::collections::BTreeMap<JobAddr, f64>,
    task_seconds: &[crate::ci::evalmap::TaskTiming],
) -> EvalMap {
    let mut document = mapping.clone();
    document.status = Some(status.clone());
    document.coverage = coverage.to_vec();
    document.build_seconds = build_seconds.clone();
    document.task_seconds = task_seconds.to_vec();
    document
}
