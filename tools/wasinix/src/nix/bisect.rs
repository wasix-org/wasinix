//! Bisect a pinned dependency while keeping the wasinix source fixed.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::ci::facts::{DependencyPath, Diagnostic, Failure};
use crate::support::atoms::JobAddr;
use crate::support::error::{Result, request_error, require};
use crate::update::select as updateselect;
use crate::update::targets::{self as updatetargets, Backend, Target};

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

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CandidateEvidence {
    pub headline: String,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub failures: BTreeMap<String, Vec<Failure>>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub diagnostics: Vec<Diagnostic>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub dependency_traces: BTreeMap<String, CandidateDependencyTrace>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CandidateDependencyTrace {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub paths: Vec<DependencyPath>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub untraced_jobs: Vec<JobAddr>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone)]
pub struct CandidateResult {
    pub outcome: Outcome,
    pub evidence: Option<CandidateEvidence>,
}

impl From<Outcome> for CandidateResult {
    fn from(outcome: Outcome) -> Self {
        CandidateResult {
            outcome,
            evidence: None,
        }
    }
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub evidence: Option<CandidateEvidence>,
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
    /// Looking for where the predicate started passing rather than where it
    /// started failing; `first_bad` is then the first commit that passed.
    #[serde(default)]
    pub reverse: bool,
    pub command: Vec<String>,
    pub first_bad: Option<String>,
    /// Commits still in range when a budget stopped the run, in git's own
    /// count. A resumed run picks up from the recorded outcomes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub revisions_left: Option<u64>,
    pub tests: Vec<TestResult>,
}

impl Report {
    pub fn boundary(&self) -> Option<&TestResult> {
        let rev = self.first_bad.as_deref()?;
        self.tests.iter().find(|test| test.rev == rev)
    }

    pub fn predicate_command(&self) -> String {
        self.command
            .iter()
            .map(|word| crate::support::shell::quote(word))
            .collect::<Vec<_>>()
            .join(" ")
    }
}

/// What one invocation may spend on candidates. A bisect is resumable, so
/// exhausting the budget narrows the range and stops; it never fails.
#[derive(Debug, Clone, Copy)]
pub struct Budget {
    pub candidates: usize,
    pub wall: Duration,
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
    let names =
        updateselect::selected_names(&updatetargets::domain(&targets), &[spec.to_string()])?;
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

/// One end of the range, named when it does not resolve. Git answers only
/// "fatal: Needed a single revision", which says neither which end nor which
/// repository, and a version typed without the tag's `v` misses by one
/// character.
fn resolve_end(
    source: &Path,
    flag: &str,
    reference: &str,
    dependency: &Dependency,
) -> Result<String> {
    // The spelling every other source grammar takes, so a reader who learned
    // it from `--with` can write it here. A bare value stays a git ref,
    // which is what a bisect range is made of.
    let reference = endpoint_source(reference, dependency)?;
    use crate::support::naming::SourceSpec;
    let tagged;
    let reference = match crate::support::naming::source_spec(&reference)? {
        SourceSpec::Revision(rev) => rev,
        SourceSpec::Tag(tag) => {
            tagged = format!("refs/tags/{tag}");
            &tagged
        }
        SourceSpec::Release(value) => value,
    };
    if let Ok(rev) = crate::support::git::resolve_rev(source, reference) {
        return Ok(rev.full().to_string());
    }
    let near = near_tags(source, reference);
    let hint = match near.as_slice() {
        [] => String::new(),
        near => format!("; did you mean {}?", near.join(" or ")),
    };
    request_error(format!(
        "--{flag} {reference}: {} has no such revision{hint}",
        dependency.repository
    ))
}

/// Accept the update grammar at a bisect endpoint without letting one
/// dependency's range accidentally name another target.
fn endpoint_source(reference: &str, dependency: &Dependency) -> Result<String> {
    let spec = crate::support::naming::parse(reference)?;
    let Some(source) = spec.value else {
        return Ok(reference.to_string());
    };
    let target = crate::support::naming::render(&spec.segments);
    require(
        target == dependency.target,
        format!(
            "{reference:?} names {target:?}, but this bisect is for {:?}",
            dependency.target
        ),
    )?;
    Ok(source)
}

/// Tags whose name contains the text. Repositories differ on the `v`
/// prefix, so the tag that does exist is the whole answer.
fn near_tags(source: &Path, reference: &str) -> Vec<String> {
    let Ok(text) = crate::support::git::git(source, &["tag", "--list", &format!("*{reference}*")])
    else {
        return Vec::new();
    };
    text.lines().take(3).map(str::to_string).collect()
}

fn resolve(repo: &Path, reference: &str) -> Result<String> {
    Ok(crate::support::git::resolve_rev(repo, reference)?
        .full()
        .to_string())
}

/// The report a run left behind, however it ended. A bisect that dies
/// mid-range has still answered part of the question, and the file is
/// written after every candidate.
pub fn read_report(run_dir: &Path) -> Option<Report> {
    crate::support::json::read(&run_dir.join(REPORT_FILE)).ok()
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
    pub reverse: bool,
    pub command: Vec<String>,
    pub run_dir: PathBuf,
    /// Absent for a terminal run, which the operator can interrupt.
    pub budget: Option<Budget>,
}

/// Drive Git's native bisect graph selection. The callback owns candidate
/// materialization and execution, which keeps this module usable in tests.
pub fn run<F>(options: Options, mut test: F) -> Result<Report>
where
    F: FnMut(&str, &Path) -> Result<CandidateResult>,
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
    let good = resolve_end(&source_dir, "good", good_ref, &options.dependency)?;
    let bad = resolve_end(&source_dir, "bad", bad_ref, &options.dependency)?;
    // Which end is the older one. A reverse bisect looks for where the
    // predicate started passing, so the failing end is the ancestor.
    let (old_ref, old_rev, new_ref, new_rev) = if options.reverse {
        (bad_ref, &bad, good_ref, &good)
    } else {
        (good_ref, &good, bad_ref, &bad)
    };
    // Three-way: exit 1 is "not an ancestor"; a git failure must not read
    // as that answer and abort the bisect with a wrong diagnosis.
    require(
        crate::support::git::is_ancestor(&source_dir, old_rev, new_rev)?,
        format!("{old_ref:?} is not an ancestor of {new_ref:?}"),
    )?;

    let report_path = options.run_dir.join(REPORT_FILE);
    let fresh = Report {
        schema: 2,
        target: options.dependency.target.clone(),
        repository: options.dependency.repository.clone(),
        good: good.clone(),
        bad: bad.clone(),
        first_parent: options.first_parent,
        reverse: options.reverse,
        command: options.command.clone(),
        first_bad: None,
        revisions_left: None,
        tests: Vec::new(),
    };
    let mut report = if report_path.exists() {
        let prior: Report = crate::support::json::read(&report_path)?;
        if prior.target == fresh.target
            && prior.repository == fresh.repository
            && prior.good == fresh.good
            && prior.bad == fresh.bad
            && prior.first_parent == fresh.first_parent
            && prior.reverse == fresh.reverse
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
        crate::support::ui::fact(
            &options.dependency.target,
            crate::support::format::short_rev(rev),
        );
        let started = Instant::now();
        let tested = test(rev, &candidate_dir)?;
        let result = TestResult {
            rev: rev.to_string(),
            outcome: tested.outcome,
            seconds: duration_seconds(started.elapsed()),
            run_dir: candidate_dir,
            evidence: tested.evidence,
        };
        report.tests.push(result);
        cached.insert(rev.to_string(), tested.outcome);
        write_report(&report_path, report)?;
        Ok(tested.outcome)
    };

    require(
        test_one(&good, &mut report)? == Outcome::Good,
        format!("--good {good_ref:?} did not pass"),
    )?;
    require(
        test_one(&bad, &mut report)? == Outcome::Bad,
        format!("--bad {bad_ref:?} did not fail"),
    )?;
    // Git always walks from its own good to its own bad, so a reverse
    // bisect hands it the ends the other way round and the callback below
    // reports the outcome the other way round with them.
    let (git_good, git_bad) = if options.reverse {
        (&bad, &good)
    } else {
        (&good, &bad)
    };
    if good == bad {
        return request_error("good and bad resolve to the same commit");
    }

    let _ = crate::support::git::git_logged(&source_dir, &["bisect", "reset"]);
    let mut start = vec!["bisect", "start", "--no-checkout"];
    if options.first_parent {
        start.push("--first-parent");
    }
    start.extend([git_bad.as_str(), git_good.as_str()]);
    let output = crate::support::git::git_logged(&source_dir, &start)?;
    if let Some(rev) = completed(&output) {
        report.first_bad = Some(rev);
    }

    let started = Instant::now();
    let mut spent = 0usize;
    let mut prior_head = None;
    while report.first_bad.is_none() {
        if let Some(budget) = &options.budget {
            if spent >= budget.candidates || started.elapsed() >= budget.wall {
                break;
            }
        }
        let rev = resolve(&source_dir, "BISECT_HEAD")?;
        require(
            prior_head.as_deref() != Some(rev.as_str()),
            format!("git bisect made no progress at {rev}"),
        )?;
        prior_head = Some(rev.clone());
        let outcome = test_one(&rev, &mut report)?;
        spent += 1;
        // Our verdict is about the predicate; git's word is about the end it
        // walks toward, and a reverse bisect walks toward the passing one.
        let word = match (options.reverse, outcome) {
            (true, Outcome::Good) => Outcome::Bad,
            (true, Outcome::Bad) => Outcome::Good,
            (_, outcome) => outcome,
        }
        .git_word();
        let output = crate::support::git::git_logged(&source_dir, &["bisect", word, &rev])?;
        report.revisions_left = revisions_left(&output);
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

/// `Bisecting: 12 revisions left to test after this` names how much range
/// survives, which is the whole answer a stopped run has to give.
fn revisions_left(output: &str) -> Option<u64> {
    let (_, rest) = output.split_once("Bisecting: ")?;
    rest.split_whitespace().next()?.parse().ok()
}

fn duration_seconds(duration: Duration) -> f64 {
    duration.as_secs_f64()
}

#[cfg(test)]
mod tests {

    use super::{
        Budget, CandidateEvidence, CandidateResult, Dependency, Duration, Options, Outcome,
        completed,
    };

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
                reverse: false,
                command: vec!["build".into(), "example".into()],
                run_dir: root.join("run"),
                budget: None,
            },
            |rev, _| {
                let outcome = if revisions[..3].iter().any(|candidate| candidate == rev) {
                    Outcome::Good
                } else {
                    Outcome::Bad
                };
                Ok(CandidateResult {
                    outcome,
                    evidence: Some(CandidateEvidence {
                        headline: format!("predicate at {rev}"),
                        ..CandidateEvidence::default()
                    }),
                })
            },
        )
        .unwrap();
        assert_eq!(report.first_bad.as_deref(), Some(revisions[3].as_str()));
        let expected = format!("predicate at {}", revisions[3]);
        assert_eq!(
            report
                .boundary()
                .and_then(|test| test.evidence.as_ref())
                .map(|evidence| evidence.headline.as_str()),
            Some(expected.as_str())
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    /// `/wasinix bisect --good 0.4.3 --bad 0.4.5 wasixcc ...` answered
    /// "error: fatal: Needed a single revision" and nothing else; the tags
    /// are `v0.4.3` and `v0.4.5`, one character away.
    #[test]
    fn an_unresolvable_end_names_itself_and_the_tag_that_exists() {
        if crate::support::git::git_global(&["--version"]).is_err() {
            return;
        }
        let root = crate::support::env::temp_dir().join(format!(
            "wasinix-bisect-refs-{}-{}",
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
        command(&source, &["commit", "--allow-empty", "-m", "one"]);
        command(&source, &["tag", "v0.4.3"]);
        let dependency = Dependency {
            target: "wasixcc".into(),
            repository: "https://github.com/wasix-org/wasixcc".into(),
            pinned: command(&source, &["rev-parse", "HEAD"]),
        };
        let error = super::resolve_end(&source, "good", "0.4.3", &dependency)
            .unwrap_err()
            .to_string();
        assert!(error.contains("--good 0.4.3"), "{error}");
        assert!(error.contains("wasix-org/wasixcc"), "{error}");
        assert!(error.contains("did you mean v0.4.3?"), "{error}");
        // The shared spellings resolve here too.
        let head = command(&source, &["rev-parse", "HEAD"]);
        for spelling in [
            format!("rev:{head}"),
            "tag:v0.4.3".to_string(),
            format!("wasixcc@rev:{head}"),
            "wasixcc@tag:v0.4.3".to_string(),
        ] {
            assert_eq!(
                super::resolve_end(&source, "good", &spelling, &dependency).unwrap(),
                head,
                "{spelling}"
            );
        }
        let wrong_target = super::resolve_end(&source, "good", "wasmer@tag:v0.4.3", &dependency)
            .unwrap_err()
            .to_string();
        assert!(
            wrong_target.contains("this bisect is for \"wasixcc\""),
            "{wrong_target}"
        );
        // Nothing near it: the refusal still names the end and the repo.
        let bare = super::resolve_end(&source, "bad", "9.9.9", &dependency)
            .unwrap_err()
            .to_string();
        assert!(bare.contains("--bad 9.9.9"), "{bare}");
        assert!(!bare.contains("did you mean"), "{bare}");
        std::fs::remove_dir_all(root).unwrap();
    }

    /// The other question: not "when did it break" but "when did it start
    /// passing". Git only ever walks toward its own bad end, so the ends and
    /// the verdicts both go in the other way round.
    #[test]
    fn a_reverse_bisect_finds_where_it_started_passing() {
        if crate::support::git::git_global(&["--version"]).is_err() {
            return;
        }
        let root = crate::support::env::temp_dir().join(format!(
            "wasinix-bisect-reverse-{}-{}",
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
        for index in 0..8 {
            command(
                &source,
                &["commit", "--allow-empty", "-m", &format!("commit {index}")],
            );
            revisions.push(command(&source, &["rev-parse", "HEAD"]));
        }
        // Broken until commit 5, passing from there on.
        let report = super::run(
            Options {
                dependency: Dependency {
                    target: "example".into(),
                    repository: source.to_string_lossy().to_string(),
                    pinned: revisions[0].clone(),
                },
                good: revisions[7].clone(),
                bad: revisions[0].clone(),
                first_parent: false,
                reverse: true,
                command: vec!["build".into(), "example".into()],
                run_dir: root.join("run"),
                budget: None,
            },
            |rev, _| {
                Ok(if revisions[..5].iter().any(|candidate| candidate == rev) {
                    Outcome::Bad
                } else {
                    Outcome::Good
                }
                .into())
            },
        )
        .unwrap();
        assert_eq!(report.first_bad.as_deref(), Some(revisions[5].as_str()));
        assert!(report.reverse);
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn a_spent_budget_narrows_the_range_and_the_next_run_finishes_it() {
        if crate::support::git::git_global(&["--version"]).is_err() {
            return;
        }
        let root = crate::support::env::temp_dir().join(format!(
            "wasinix-bisect-budget-{}-{}",
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
        for index in 0..16 {
            command(
                &source,
                &["commit", "--allow-empty", "-m", &format!("commit {index}")],
            );
            revisions.push(command(&source, &["rev-parse", "HEAD"]));
        }
        let options = |budget| Options {
            dependency: Dependency {
                target: "example".into(),
                repository: source.to_string_lossy().to_string(),
                pinned: revisions[0].clone(),
            },
            good: "pinned".into(),
            bad: revisions[15].clone(),
            first_parent: false,
            reverse: false,
            command: vec!["build".into(), "example".into()],
            run_dir: root.join("run"),
            budget,
        };
        let mut tested = 0usize;
        let verdict = |rev: &str| {
            if revisions[..9].iter().any(|candidate| candidate == rev) {
                Outcome::Good
            } else {
                Outcome::Bad
            }
        };
        let stopped = super::run(
            options(Some(Budget {
                candidates: 1,
                wall: Duration::from_secs(3600),
            })),
            |rev, _| {
                tested += 1;
                Ok(verdict(rev).into())
            },
        )
        .unwrap();
        assert!(
            stopped.first_bad.is_none(),
            "one candidate cannot decide 16"
        );
        assert!(
            stopped.revisions_left.is_some(),
            "the range was not narrowed"
        );

        // Resuming reuses the recorded outcomes: the good and bad ends are
        // not retested, and the run finishes.
        let before = tested;
        let finished = super::run(options(None), |rev, _| {
            tested += 1;
            Ok(verdict(rev).into())
        })
        .unwrap();
        assert_eq!(finished.first_bad.as_deref(), Some(revisions[9].as_str()));
        assert!(
            tested - before < finished.tests.len(),
            "a resumed run retested everything"
        );
        std::fs::remove_dir_all(root).unwrap();
    }
}
