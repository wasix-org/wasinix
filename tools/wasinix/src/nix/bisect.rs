//! Bisect a pinned dependency while keeping the wasinix source fixed.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::support::error::{request_error, require, Result};
use crate::update::targets::{self as updatetargets, Backend, Target};
use crate::update::select as updateselect;

/// The report the run leaves beside its candidate dirs.
pub const REPORT_FILE: &str = "bisect.json";

#[derive(Debug, Clone)]
pub struct Dependency {
    pub target: String,
    pub repository: String,
    pub pinned: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Outcome {
    Good,
    Bad,
    Skip,
}

impl Outcome {
    fn git_word(self) -> &'static str {
        match self {
            Outcome::Good => "good",
            Outcome::Bad => "bad",
            Outcome::Skip => "skip",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TestResult {
    pub rev: String,
    pub outcome: Outcome,
    pub seconds: f64,
    pub run_dir: PathBuf,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Report {
    pub schema: u32,
    pub target: String,
    pub repository: String,
    pub good: String,
    pub bad: String,
    pub first_parent: bool,
    pub command: Vec<String>,
    pub first_bad: Option<String>,
    pub tests: Vec<TestResult>,
}

fn source_repository(source: &Value) -> Option<String> {
    match source["kind"].as_str()? {
        "github" => Some(format!(
            "https://github.com/{}/{}.git",
            source["owner"].as_str()?,
            source["repo"].as_str()?
        )),
        "git" => source["url"].as_str().map(str::to_string),
        _ => None,
    }
}

/// Resolve the same target names accepted by `update` and `--with`.
pub fn dependency(repo: &Path, spec: &str) -> Result<Dependency> {
    let targets = updatetargets::all_targets(repo)?;
    let names = updateselect::selected_names(&updatetargets::domain(&targets), &[spec.to_string()])?;
    require(
        names.len() == 1,
        format!("bisect target {spec:?} is ambiguous"),
    )?;
    let name = &names[0];
    let target = targets
        .iter()
        .find(|target| &target.name == name)
        .expect("resolved target exists");
    require(
        target.accepts.iter().any(|value| value == "revision"),
        format!("{} does not accept revision overrides", target.name),
    )?;
    let source = target.source.as_ref().unwrap_or(&Value::Null);
    let repository = source_repository(source).ok_or_else(|| {
        crate::support::error::Error::Request(format!("{} has no Git source", target.name))
    })?;
    let pinned = pinned_revision(repo, target)?;
    require(
        !pinned.is_empty(),
        format!("{} has no pinned Git revision", target.name),
    )?;
    Ok(Dependency {
        target: target.name.clone(),
        repository,
        pinned,
    })
}

fn pinned_revision(repo: &Path, target: &Target) -> Result<String> {
    if target.backend == Backend::FlakeInput {
        return Ok(target.version.clone());
    }
    let source = target.source.as_ref().unwrap_or(&Value::Null);
    if let Some(rev) = source["rev"].as_str() {
        return Ok(rev.to_string());
    }
    // Package declarations describe the upstream, while the fetched source is
    // the authority for its current pin.
    let expression = "p: p.src.rev or p.src.tag or \"\"";
    let flake = repo.to_string_lossy();
    let value = crate::support::nix::eval(
        &crate::support::nix::Flake(&flake),
        &target.address(),
        Some(expression),
    )?;
    Ok(value.as_str().unwrap_or_default().to_string())
}

fn resolve(repo: &Path, reference: &str) -> Result<String> {
    Ok(crate::support::git::resolve_rev(repo, reference)?
        .full()
        .to_string())
}

pub(crate) fn completed(output: &str) -> Option<String> {
    output.lines().find_map(|line| {
        let (rev, rest) = line.split_once(" is the first")?;
        if !rest.contains("bad") || !rest.ends_with("commit") {
            return None;
        }
        let rev = rev
            .trim()
            .trim_start_matches('[')
            .split_whitespace()
            .next()?;
        crate::support::atoms::Rev::parse(rev)
            .ok()
            .map(|rev| rev.full().to_string())
    })
}

fn write_report(path: &Path, report: &Report) -> Result<()> {
    crate::support::json::write(path, report)
}

pub struct Options {
    pub dependency: Dependency,
    pub good: String,
    pub bad: String,
    pub first_parent: bool,
    pub command: Vec<String>,
    pub run_dir: PathBuf,
}

/// Drive Git's native bisect graph selection. The callback owns candidate
/// materialization and execution, which keeps this module usable in tests.
pub fn run<F>(options: Options, mut test: F) -> Result<Report>
where
    F: FnMut(&str, &Path) -> Result<Outcome>,
{
    crate::support::fs::create_dir_all(&options.run_dir)?;
    let source_dir = options.run_dir.join("source.git");
    if !source_dir.exists() {
        let source = source_dir.to_string_lossy().to_string();
        crate::support::git::git_global(&[
            "clone",
            "--bare",
            "--filter=blob:none",
            &options.dependency.repository,
            &source,
        ])?;
    } else {
        crate::support::git::git_logged(&source_dir, &["fetch", "--prune", "origin"])?;
    }
    let good_ref = if options.good == "pinned" {
        &options.dependency.pinned
    } else {
        &options.good
    };
    let bad_ref = if options.bad == "pinned" {
        &options.dependency.pinned
    } else {
        &options.bad
    };
    let good = resolve(&source_dir, good_ref)?;
    let bad = resolve(&source_dir, bad_ref)?;
    // Three-way: exit 1 is "not an ancestor"; a git failure must not read
    // as that answer and abort the bisect with a wrong diagnosis.
    require(
        crate::support::git::is_ancestor(&source_dir, &good, &bad)?,
        format!("good revision {good_ref:?} is not an ancestor of bad revision {bad_ref:?}"),
    )?;

    let report_path = options.run_dir.join(REPORT_FILE);
    let fresh = Report {
        schema: 1,
        target: options.dependency.target.clone(),
        repository: options.dependency.repository.clone(),
        good: good.clone(),
        bad: bad.clone(),
        first_parent: options.first_parent,
        command: options.command.clone(),
        first_bad: None,
        tests: Vec::new(),
    };
    let mut report = if report_path.exists() {
        let prior: Report = crate::support::json::read(&report_path)?;
        if prior.target == fresh.target
            && prior.repository == fresh.repository
            && prior.good == fresh.good
            && prior.bad == fresh.bad
            && prior.first_parent == fresh.first_parent
            && prior.command == fresh.command
        {
            prior
        } else {
            fresh
        }
    } else {
        fresh
    };
    if report.first_bad.is_some() {
        return Ok(report);
    }
    let mut cached: BTreeMap<String, Outcome> = report
        .tests
        .iter()
        .map(|result| (result.rev.clone(), result.outcome))
        .collect();

    let mut test_one = |rev: &str, report: &mut Report| -> Result<Outcome> {
        if let Some(outcome) = cached.get(rev) {
            return Ok(*outcome);
        }
        let candidate_dir = options.run_dir.join("candidates").join(rev);
        crate::support::ui::fact(&options.dependency.target, crate::support::format::short_rev(rev));
        let started = Instant::now();
        let outcome = test(rev, &candidate_dir)?;
        let result = TestResult {
            rev: rev.to_string(),
            outcome,
            seconds: duration_seconds(started.elapsed()),
            run_dir: candidate_dir,
        };
        report.tests.push(result);
        cached.insert(rev.to_string(), outcome);
        write_report(&report_path, report)?;
        Ok(outcome)
    };

    require(
        test_one(&good, &mut report)? == Outcome::Good,
        format!("--good {good_ref:?} did not pass"),
    )?;
    require(
        test_one(&bad, &mut report)? == Outcome::Bad,
        format!("--bad {bad_ref:?} did not fail"),
    )?;
    if good == bad {
        return request_error("good and bad resolve to the same commit");
    }

    let _ = crate::support::git::git_logged(&source_dir, &["bisect", "reset"]);
    let mut start = vec!["bisect", "start", "--no-checkout"];
    if options.first_parent {
        start.push("--first-parent");
    }
    start.extend([bad.as_str(), good.as_str()]);
    let output = crate::support::git::git_logged(&source_dir, &start)?;
    if let Some(rev) = completed(&output) {
        report.first_bad = Some(rev);
    }

    let mut prior_head = None;
    while report.first_bad.is_none() {
        let rev = resolve(&source_dir, "BISECT_HEAD")?;
        require(
            prior_head.as_deref() != Some(rev.as_str()),
            format!("git bisect made no progress at {rev}"),
        )?;
        prior_head = Some(rev.clone());
        let outcome = test_one(&rev, &mut report)?;
        let output = crate::support::git::git_logged(&source_dir, &["bisect", outcome.git_word(), &rev])?;
        if let Some(rev) = completed(&output) {
            report.first_bad = Some(rev);
            break;
        }
        if output.contains("only skipped commits left") {
            return request_error(format!("bisect is ambiguous:\n{output}"));
        }
    }
    write_report(&report_path, &report)?;
    let _ = crate::support::git::git_logged(&source_dir, &["bisect", "reset"]);
    Ok(report)
}

fn duration_seconds(duration: Duration) -> f64 {
    duration.as_secs_f64()
}

#[cfg(test)]
mod tests {

    use super::{completed, Dependency, Options, Outcome};

    #[test]
    fn reads_first_bad_commit() {
        let rev = "0123456789abcdef0123456789abcdef01234567";
        assert_eq!(
            completed(&format!("{rev} is the first bad commit\n")),
            Some(rev.to_string())
        );
        assert_eq!(
            completed(&format!("{rev} is the first 'bad' commit\n")),
            Some(rev.to_string())
        );
        assert_eq!(
            completed(&format!("[{rev}] subject\n{rev} is the first bad commit")),
            Some(rev.to_string())
        );
    }

    fn command(repo: &std::path::Path, args: &[&str]) -> String {
        crate::support::git::git(repo, args).unwrap()
    }

    #[test]
    fn native_git_bisect_selects_the_first_bad_revision() {
        if crate::support::git::git_global(&["--version"]).is_err() {
            return;
        }
        let root = crate::support::env::temp_dir().join(format!(
            "wasinix-bisect-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let source = root.join("upstream");
        std::fs::create_dir_all(&source).unwrap();
        command(&source, &["init", "--initial-branch=main"]);
        command(&source, &["config", "user.name", "wasinix test"]);
        command(&source, &["config", "user.email", "test@example.invalid"]);
        let mut revisions = Vec::new();
        for index in 0..6 {
            command(
                &source,
                &["commit", "--allow-empty", "-m", &format!("commit {index}")],
            );
            revisions.push(command(&source, &["rev-parse", "HEAD"]));
        }
        let report = super::run(
            Options {
                dependency: Dependency {
                    target: "example".into(),
                    repository: source.to_string_lossy().to_string(),
                    pinned: revisions[0].clone(),
                },
                good: "pinned".into(),
                bad: revisions[5].clone(),
                first_parent: false,
                command: vec!["build".into(), "example".into()],
                run_dir: root.join("run"),
            },
            |rev, _| {
                Ok(if revisions[..3].iter().any(|candidate| candidate == rev) {
                    Outcome::Good
                } else {
                    Outcome::Bad
                })
            },
        )
        .unwrap();
        assert_eq!(report.first_bad.as_deref(), Some(revisions[3].as_str()));
        std::fs::remove_dir_all(root).unwrap();
    }
}
