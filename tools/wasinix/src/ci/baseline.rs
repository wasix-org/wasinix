//! Reuse a published main-branch evaluation as a diff's baseline side. The
//! baseline is usually a revision main already built; fetching that run's
//! evaluation and per-job status costs one request where rebuilding it costs
//! a full evaluation and, on a toolchain change, a full build.

use std::path::Path;

use crate::ci::compare::JobStatuses;
use crate::ci::evalmap::{EvalMap, StatusMap};
use crate::ci::types::{Build, RevSource};
use crate::support::atoms::JobAddr;
use crate::support::error::Result;



/// A published baseline, or `None` with the reason surfaced: an absent or
/// incompatible baseline degrades to building the base side, never to a red
/// run and never silently.
/// The template the production reuse path fetches; tests substitute a local
/// server's.
pub fn map_url_template() -> String {
    format!(
        "{}/eval-maps/{{tree}}.json",
        crate::support::nix::CACHE_SUBSTITUTER
    )
}

/// Fetch the map published for a git tree object id. The tree determines the
/// evaluation, so the key verifies itself: no run can publish under a tree
/// it did not build. A template without a scheme is read from the
/// filesystem, which the tests use.
pub fn fetch(tree: &str, url_template: &str, label: &str) -> Option<EvalMap> {
    let url = url_template.replace("{tree}", tree);
    let value = if url.contains("://") {
        crate::support::http::get_json(&url)
    } else {
        crate::support::json::read(Path::new(&url))
    };
    let value = match value {
        Ok(value) => value,
        Err(error) => {
            crate::support::ui::fact(label, format!("off ({error})"));
            return None;
        }
    };
    let published: EvalMap = match crate::support::schema::from_value(value, &url) {
        Ok(published) => published,
        Err(error) => {
            crate::support::ui::fact(label, format!("off ({error})"));
            return None;
        }
    };
    // Coverage makes a partial or interrupted build distinguishable from a
    // complete baseline. A status map alone cannot: it may contain just the
    // jobs that happened to finish before cancellation.
    if published.status.is_none() || published.coverage.is_empty() {
        crate::support::ui::fact(
            label,
            "off (published map carries no status coverage)",
        );
        return None;
    }
    Some(published)
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
    let covered: std::collections::BTreeSet<&str> = published
        .coverage
        .iter()
        .map(JobAddr::as_str)
        .collect();
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
    // The key is the materialized tree's object id, recorded at prepare
    // time, so a patched or overridden run publishes under its own tree and
    // can never claim a commit's.
    let manifest: crate::ci::workspace::Materialization =
        crate::support::schema::read(&paths.join("prepared/materialization.json"))?;
    let mapping: EvalMap = crate::support::schema::read(&crate::ci::prepare::eval_map_path(&paths))?;
    let rev = mapping
        .rev
        .clone()
        .ok_or_else(|| crate::support::error::Error::Failure(
            "the eval map names no revision to publish under".into(),
        ))?;
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
    let mut junits: Vec<std::path::PathBuf> = std::fs::read_dir(crate::ci::prepare::junit_dir(&paths))
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
    let mut cmd = std::process::Command::new("aws");
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

/// The document a completed build publishes for later reuse: its eval map
/// with status, coverage, and build times folded in.
pub fn publish_document(
    mapping: &EvalMap,
    status: &StatusMap,
    coverage: &[JobAddr],
    build_seconds: &std::collections::BTreeMap<JobAddr, f64>,
) -> EvalMap {
    let mut document = mapping.clone();
    document.status = Some(status.clone());
    document.coverage = coverage.to_vec();
    document.build_seconds = build_seconds.clone();
    document
}
