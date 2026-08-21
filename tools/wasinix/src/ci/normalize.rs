//! Turn a parsed request into one pinned to commits. Resolution is the only
//! way to obtain a `RevSource`, so nothing downstream can accidentally build
//! a moving reference.

use std::collections::HashMap;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::ci::types::{
    Build, Case, Diff, Override, OverrideKind, ParsedRequest, RefSource, Request, RequestAction,
    ResolvedRequest, RevSource, Spot,
};
use crate::support::error::{Result, request_error};
use crate::support::git;

static PR_SPEC: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(
        r"^([A-Za-z0-9][A-Za-z0-9._-]{0,38})/([A-Za-z0-9][A-Za-z0-9._-]{0,99})#([1-9][0-9]*)$",
    )
    .unwrap()
});
fn resolve_source(repo: &Path, source: &RefSource) -> Result<RevSource> {
    Ok(RevSource {
        rev: git::resolve_rev(repo, &source.reference)?,
        patch: None,
        working_tree: source.reference == "HEAD",
    })
}

/// The repository the checkout builds. Deliberately not $GITHUB_REPOSITORY:
/// a workflow in another repo can drive this checkout, and its event repo is
/// where replies go, not what is being built.
pub fn current_repository(repo: &Path) -> String {
    crate::github::surfaces::origin_repository(repo).unwrap_or_default()
}

/// The pull request a `--from-pr` refers to.
pub struct PullRequest {
    pub base_repository: String,
    pub head_sha: String,
    pub url: String,
}

/// What a bare `--from-pr` resolves against: the verified origin the adapter
/// recorded, when the run came from a cross-repository command, else the
/// GitHub event the workflow is running for.
pub struct Context<'a> {
    pub repo: &'a Path,
    pub origin: Option<&'a crate::ci::origin::Origin>,
}

fn current_pull_request(context: &Context<'_>) -> Result<PullRequest> {
    if let Some(origin) = context.origin {
        return Ok(PullRequest {
            head_sha: origin.head_sha.clone(),
            url: format!(
                "https://github.com/{}/pull/{}",
                origin.repository, origin.pull_request
            ),
            base_repository: origin.repository.clone(),
        });
    }
    let Some(path) = crate::support::env::github_event_path()? else {
        return request_error("bare --from-pr requires a GitHub pull_request event");
    };
    let event: Value = crate::support::json::read(Path::new(&path))?;
    let pull = &event["pull_request"];
    if pull.is_null() {
        return request_error("bare --from-pr requires a GitHub pull_request event");
    }
    Ok(PullRequest {
        base_repository: pull["base"]["repo"]["full_name"]
            .as_str()
            .unwrap_or_default()
            .to_string(),
        head_sha: pull["head"]["sha"].as_str().unwrap_or_default().to_string(),
        url: pull["html_url"].as_str().unwrap_or_default().to_string(),
    })
}

pub fn resolve_pull_request(spec: &str, context: &Context<'_>) -> Result<PullRequest> {
    if spec == "current" {
        return current_pull_request(context);
    }
    let captures = match PR_SPEC.captures(spec) {
        Some(captures) => captures,
        None => return request_error("--from-pr expects OWNER/REPO#NUMBER"),
    };
    let (owner, repo, number) = (&captures[1], &captures[2], &captures[3]);
    let pull = crate::github::client::Client::new(None)
        .get(&format!("repos/{owner}/{repo}/pulls/{number}"))?;
    Ok(PullRequest {
        base_repository: pull["base"]["repo"]["full_name"]
            .as_str()
            .unwrap_or_default()
            .to_string(),
        head_sha: pull["head"]["sha"].as_str().unwrap_or_default().to_string(),
        url: pull["html_url"].as_str().unwrap_or_default().to_string(),
    })
}

/// Which update target a repository maps to, discovered from the flake rather
/// than hardcoded, so a new pinned dependency needs no change here.
pub fn update_sources(repo: &Path) -> Result<HashMap<String, Vec<String>>> {
    let mut sources: HashMap<String, Vec<String>> = Default::default();
    for target in crate::update::targets::all_targets(repo)? {
        let Some(source) = target.source else {
            continue;
        };
        if source["kind"].as_str() != Some("github") {
            continue;
        }
        let key = format!(
            "{}/{}",
            source["owner"].as_str().unwrap_or_default(),
            source["repo"].as_str().unwrap_or_default()
        )
        .to_lowercase();
        sources.entry(key).or_default().push(target.name);
    }
    Ok(sources)
}

/// Apply a `--from-pr`: either the PR is against this repository, in which case
/// it names the revision to build, or it is against a pinned dependency, in
/// which case it becomes an override on that pin.
fn apply_pull_request(
    source: &mut RevSource,
    overrides: &mut Vec<Override>,
    pull: &PullRequest,
    context: &Context<'_>,
    sources: &mut Option<HashMap<String, Vec<String>>>,
) -> Result<()> {
    let head_sha = pull.head_sha.to_lowercase();
    let current = current_repository(context.repo);
    if !current.is_empty() && pull.base_repository.to_lowercase() == current {
        // Only the revision moves; the case keeps its patch and working-tree
        // status, which a whole-source replacement would silently drop.
        source.rev = crate::support::atoms::Rev::parse(&head_sha)?;
        source.working_tree = false;
        return Ok(());
    }
    if sources.is_none() {
        *sources = Some(update_sources(context.repo)?);
    }
    let empty = Vec::new();
    let matches = sources
        .as_ref()
        .unwrap()
        .get(&pull.base_repository.to_lowercase())
        .unwrap_or(&empty);
    if matches.len() != 1 {
        let found = if matches.is_empty() {
            "none".to_string()
        } else {
            matches.join(", ")
        };
        return request_error(format!(
            "PR repository {} maps to {} update targets ({found})",
            pull.base_repository,
            matches.len()
        ));
    }
    let target = matches[0].clone();
    if overrides.iter().any(|value| value.target == target) {
        return request_error(format!("--from-pr duplicates explicit override {target}"));
    }
    overrides.push(Override {
        target,
        kind: OverrideKind::Revision,
        value: head_sha,
        repository: Some(pull.base_repository.clone()),
        origin: Some(pull.url.clone()),
    });
    Ok(())
}

fn normalize_build(
    build: &Build<RefSource>,
    context: &Context<'_>,
    sources: &mut Option<HashMap<String, Vec<String>>>,
) -> Result<Build<RevSource>> {
    let mut source = resolve_source(context.repo, &build.source)?;
    let mut overrides = build.overrides.clone();
    if let Some(spec) = &build.from_pr {
        let pull = resolve_pull_request(spec, context)?;
        apply_pull_request(&mut source, &mut overrides, &pull, context, sources)?;
    }
    Ok(Build {
        case_id: build.case_id.clone(),
        source,
        selectors: build.selectors.clone(),
        enabled_tags: build.enabled_tags.clone(),
        overrides,
        from_pr: None,
        on: build.on.clone(),
    })
}

fn normalize_spot(
    spot: &Spot<RefSource>,
    context: &Context<'_>,
    sources: &mut Option<HashMap<String, Vec<String>>>,
) -> Result<Spot<RevSource>> {
    let mut source = resolve_source(context.repo, &spot.source)?;
    let mut overrides = spot.overrides.clone();
    if let Some(spec) = &spot.from_pr {
        let pull = resolve_pull_request(spec, context)?;
        apply_pull_request(&mut source, &mut overrides, &pull, context, sources)?;
    }
    let base = match &spot.base {
        Some(base) => git::resolve_rev(context.repo, base)?.full().to_string(),
        None => source.rev.full().to_string(),
    };
    Ok(Spot {
        case_id: spot.case_id.clone(),
        source,
        targets: spot.targets.clone(),
        from_source: spot.from_source.clone(),
        base: Some(base),
        overrides,
        from_pr: None,
        on: spot.on.clone(),
    })
}

pub fn normalize(request: &ParsedRequest, context: &Context<'_>) -> Result<ResolvedRequest> {
    let mut sources = None;
    let action = match &request.action {
        RequestAction::Build(build) => {
            RequestAction::Build(normalize_build(build, context, &mut sources)?)
        }
        RequestAction::Spot(spot) => {
            RequestAction::Spot(normalize_spot(spot, context, &mut sources)?)
        }
        RequestAction::Diff(diff) => {
            let mut cases = Vec::new();
            for case in &diff.cases {
                cases.push(match case {
                    Case::Build(case) => Case::Build(normalize_build(case, context, &mut sources)?),
                    Case::Spot(case) => Case::Spot(normalize_spot(case, context, &mut sources)?),
                });
            }
            RequestAction::Diff(Diff {
                baseline: diff.baseline.clone(),
                content_diff: diff.content_diff,
                cases,
            })
        }
    };
    Ok(Request {
        blocked: request.blocked,
        action,
    })
}

/// Canonical JSON: sorted keys, no whitespace. The request id is a digest of
/// this, so two implementations agree only if their requests are identical.
fn canonical(value: &Value) -> String {
    match value {
        Value::Object(map) => {
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort();
            let body: Vec<String> = keys
                .iter()
                .map(|key| {
                    format!(
                        "{}:{}",
                        Value::String((*key).clone()),
                        canonical(&map[*key])
                    )
                })
                .collect();
            format!("{{{}}}", body.join(","))
        }
        Value::Array(items) => {
            let body: Vec<String> = items.iter().map(canonical).collect();
            format!("[{}]", body.join(","))
        }
        other => other.to_string(),
    }
}

/// The identity of a request or case document, derived from its enveloped
/// content on demand and never stored beside it, so no copy can disagree.
pub fn request_id(value: &Value) -> String {
    let digest = Sha256::digest(canonical(value).as_bytes());
    format!("{digest:x}")[..20].to_string()
}
