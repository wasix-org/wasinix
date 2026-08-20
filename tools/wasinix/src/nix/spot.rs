//! Build one or more attrs from a worktree with everything below them pinned
//! to a cached base revision. The output mixes objects from two toolchains,
//! so a green spot build is experimental evidence, not a shipping verdict.

use std::path::Path;

use serde::Deserialize;

use crate::nix::route::Route;
use crate::support::error::{Error, Result, request_error};
use crate::support::nix::Invocation;
use crate::support::process::CommandStatus;

pub struct Options {
    /// `<profile>.<attr>` paths into nixpkgsByProfile.
    pub targets: Vec<String>,
    /// Pristine revision to pin below the targets.
    pub base: String,
    pub source_owners: Vec<String>,
    pub dry_run: bool,
    /// Extra arguments for the underlying `nix build`.
    pub nix_args: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TargetResult {
    pub target: String,
    pub spliced_drv_path: String,
}

#[derive(Debug, Clone)]
pub struct BuildResult {
    pub status: CommandStatus,
    pub targets: Vec<TargetResult>,
}

#[derive(Deserialize)]
struct Report {
    changed: bool,
    targets: Vec<TargetResult>,
}

/// A Nix list literal. Every element reaching here is already constrained to
/// an attr name, so nothing can close the string it lands in.
pub(crate) fn nix_list(values: &[String]) -> Result<String> {
    for value in values {
        if value.contains(['"', '\\', '$']) {
            return request_error(format!("{value:?}: not an attr name"));
        }
    }
    let quoted: Vec<String> = values.iter().map(|value| format!("\"{value}\"")).collect();
    Ok(format!("[{}]", quoted.join(" ")))
}

/// The splice's own arguments, shared by every phase of a run.
fn splice_args(repo: &Path, workdir: &Path, rev: &str, options: &Options) -> Result<Vec<String>> {
    Ok(vec![
        "-f".to_string(),
        repo.join("spot.nix").to_string_lossy().to_string(),
        "--impure".to_string(),
        "--arg".to_string(),
        "targets".to_string(),
        nix_list(&options.targets)?,
        "--argstr".to_string(),
        "base".to_string(),
        rev.to_string(),
        // The tree to splice from. Without it spot.nix falls back to its own
        // directory, so a run driven from a materialized worktree would build
        // the checkout the tool was invoked from instead.
        "--argstr".to_string(),
        "root".to_string(),
        workdir.to_string_lossy().to_string(),
        "--arg".to_string(),
        "keep".to_string(),
        nix_list(&options.source_owners)?,
    ])
}

fn splice(workdir: &Path, subcommand: &str, args: &[String]) -> Invocation {
    // The splice file evaluates the checkout as a flake, so the repo's
    // nixConfig (the shared cache) must apply or base rebuilds from source.
    Invocation::plain(subcommand)
        .accepts_flake_config()
        .args(args.iter().cloned())
        .workdir(workdir)
}

/// How many derivations a plan would build. Nix says "these N derivations
/// will be built" for N > 1 and "this derivation will be built" for exactly
/// one, so a one-build plan would otherwise report zero.
fn planned_builds(workdir: &Path, args: &[String], attr: &str, route: &Route) -> Result<usize> {
    let probe = splice(workdir, "build", args)
        .arg("--dry-run")
        .operand(attr)
        .route(route)?
        .probe("a dry-run plan reports its count on stderr")?;
    let text = &probe.stderr;
    let mut lines = text.lines();
    while let Some(line) = lines.next() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix("these ") {
            if let Some((count, _)) = rest.split_once(' ') {
                if let Ok(count) = count.parse() {
                    return Ok(count);
                }
            }
        }
        if line.starts_with("this derivation will be built") {
            return Ok(1);
        }
        // A store that only prices the plan (ssh-ng) phrases the same
        // would-build set as paths it cannot build; the count is the drv
        // list under the marker.
        if line.starts_with("don't know how to build these paths") {
            return Ok(lines
                .map(str::trim)
                .take_while(|line| line.starts_with("/nix/store/"))
                .count());
        }
    }
    // A phrasing this parser does not know must not read as "fully cached".
    if text.contains(".drv") {
        return Err(crate::support::error::Error::Failure(format!(
            "unrecognized dry-run plan phrasing:\n{}",
            crate::support::error::tail(text, 500)
        )));
    }
    Ok(0)
}

/// `repo` holds spot.nix; `workdir` is the tree to build from, which is a
/// materialized worktree when CI drives this and the checkout itself
/// otherwise.
pub fn build(repo: &Path, workdir: &Path, options: &Options, route: &Route) -> Result<BuildResult> {
    if options.targets.is_empty() {
        return request_error("spot needs at least one <profile>.<attr> target");
    }
    let rev = crate::support::git::resolve_rev(workdir, &options.base).map_err(|_| {
        Error::Request(format!("{}: not a commit in this repository", options.base))
    })?;
    let args = splice_args(repo, workdir, rev.full(), options)?;
    let _lease = route.acquire()?;
    crate::support::ui::fact("spot targets", options.targets.join(" "));
    crate::support::ui::fact("spot base", &rev);
    crate::support::ui::fact(
        "spot source",
        if options.source_owners.is_empty() {
            "target-only".to_string()
        } else {
            options.source_owners.join(",")
        },
    );

    // Refuse a no-op: if nothing about the target changed, the pins are the
    // whole story and the build would re-download base's own output.
    let probed = splice(workdir, "eval", &args)
        .json()
        .operand("report")
        .route(route)?
        .probe("a failing splice eval is reported with its own stderr")?;
    if !probed.status.is_success() {
        return request_error(format!(
            "evaluating the splice failed:\n{}",
            probed.stderr.trim()
        ));
    }
    let report: Report = serde_json::from_slice(&probed.stdout).map_err(|source| Error::Json {
        path: "<spot report>".into(),
        source,
    })?;
    if !report.changed {
        return request_error(
            "every target is identical to base; the working tree does not reach them.\n\
             A toolchain edit reaches any target by default. For a dependency change, pass\n\
             --from-source with its CI selector. Check that the change is in a tracked file.",
        );
    }

    if options.dry_run {
        // Two counts, because "N to build" alone conflates the compiles the
        // change causes with base artifacts that were never cached. `base rev`
        // should be 0; if it is not, most of the run is rebuilding base rather
        // than testing the change, so pick a revision CI has built.
        crate::support::ui::fact(
            "spot base rev",
            format!(
                "{} to build (want 0; nonzero = --base not cached)",
                planned_builds(workdir, &args, "baseDrv", route)?
            ),
        );
        crate::support::ui::fact(
            "spot this run",
            format!(
                "{} to build",
                planned_builds(workdir, &args, "spliced", route)?
            ),
        );
    }

    // The route applies to the dry-run too: the plan must be priced under
    // the same placement as the real build, or the two counts printed above
    // describe different worlds.
    let mut build = splice(workdir, "build", &args)
        .operand("spliced")
        .route(route)?;
    build = if options.dry_run {
        build.arg("--dry-run")
    } else {
        build.arg("--print-build-logs")
    };
    build = build.args(options.nix_args.iter().cloned());
    Ok(BuildResult {
        status: build.status()?,
        targets: report.targets,
    })
}
