//! Which targets a set of specs selects, and the explicit requests they
//! carry. `TARGET@VERSION`, `TARGET@tag:NAME` and `TARGET@rev:SOURCE` are
//! the whole grammar, shared with `--with`.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::support::error::{Result, request_error};
use crate::support::naming::{self, Domain};
use crate::update::targets::{Backend, Target};
use crate::update::{Mode, Request};

/// Resolve target names and globs.
pub fn selected_names(domain: &Domain, specs: &[String]) -> Result<Vec<String>> {
    let mut names = Vec::new();
    for resolved in naming::resolve_all(domain, specs)? {
        if resolved.value.is_some() {
            return request_error("target selectors do not take @ values");
        }
        names.push(resolved.key);
    }
    Ok(names)
}

fn parse_revision(name: &str, value: &str, owner: &str, repo: &str) -> Result<String> {
    if let Some(rest) = value.strip_prefix("github:") {
        let Some((path, rev)) = rest.rsplit_once('@') else {
            return request_error(format!(
                "{name} revision expects a 40-character commit SHA or github:OWNER/REPO@SHA"
            ));
        };
        let Some((requested_owner, requested_repo)) = path.split_once('/') else {
            return request_error(format!("{name} revision source must be {owner}/{repo}"));
        };
        if !requested_owner.eq_ignore_ascii_case(owner)
            || !requested_repo.eq_ignore_ascii_case(repo)
        {
            return request_error(format!("{name} revision source must be {owner}/{repo}"));
        }
        if crate::support::atoms::Rev::parse(rev).is_err() {
            return request_error(format!(
                "{name} revision expects a 40-character commit SHA or github:OWNER/REPO@SHA"
            ));
        }
        return Ok(rev.to_lowercase());
    }
    if crate::support::atoms::Rev::parse(value).is_ok() {
        return Ok(value.to_lowercase());
    }
    request_error(format!(
        "{name} revision expects a 40-character commit SHA or github:OWNER/REPO@SHA"
    ))
}

/// The commit a tag points at, read straight from the target's own remote.
/// Resolving it here keeps `tag:` a spelling rather than a third kind of
/// pin: everything downstream sees the revision it names.
fn resolve_tag(targets: &[Target], name: &str, tag: &str) -> Result<String> {
    let target = targets
        .iter()
        .find(|target| target.name == name)
        .ok_or_else(|| crate::support::error::Error::Request(format!("unknown target {name:?}")))?;
    let Some(repository) = target
        .source
        .as_ref()
        .and_then(crate::update::upstream::source_repository)
    else {
        return request_error(format!(
            "tag:{tag}: {name} declares no git source to resolve a tag against"
        ));
    };
    let output = crate::support::git::git_global(&[
        "ls-remote",
        "--tags",
        &repository,
        &format!("refs/tags/{tag}"),
        &format!("refs/tags/{tag}^{{}}"),
    ])?;
    match tag_commit(&output) {
        Some(sha) => Ok(sha.to_string()),
        None => request_error(format!("tag:{tag}: {repository} has no such tag")),
    }
}

/// The commit an `ls-remote` answer names. An annotated tag lists the tag
/// object and, as `<ref>^{}`, the commit it dereferences to; pinning the tag
/// object would pin something no build can check out.
pub(crate) fn tag_commit(output: &str) -> Option<&str> {
    let mut found = None;
    for line in output.lines() {
        let Some((sha, reference)) = line.split_once('\t') else {
            continue;
        };
        if reference.ends_with("^{}") {
            return Some(sha);
        }
        found = found.or(Some(sha));
    }
    found
}

/// A manual revision must already be merged upstream. Nothing else stops a
/// pin naming a pull-request head: the commit is fetchable, so it locks and
/// builds, and the pin then rides on code that may never be merged and that
/// no release will ever contain. A tag skips this — a release is
/// authoritative even when it was cut off a release branch.
fn require_merged(targets: &[Target], name: &str, rev: &str) -> Result<()> {
    let Some(target) = targets.iter().find(|target| target.name == name) else {
        return request_error(format!("unknown target {name:?}"));
    };
    if !target.release_line {
        return Ok(());
    }
    // A malformed revision is the request grammar's error to report, with
    // its own message; this gate must not answer it with "not merged".
    if crate::support::atoms::Rev::parse(rev).is_err() {
        return Ok(());
    }
    let Some(repository) = target
        .source
        .as_ref()
        .and_then(crate::update::upstream::source_repository)
    else {
        return request_error(format!(
            "rev:{rev}: {name} declares no git source to check the revision against"
        ));
    };
    let mirror = crate::update::upstream::mirror(&repository)?;
    if crate::update::upstream::is_merged(&mirror, rev)? {
        return Ok(());
    }
    request_error(format!(
        "rev:{rev}: not merged into {repository} {}; pin a merged commit, \
         not a pull-request head",
        crate::update::upstream::TRUNK
    ))
}

/// Validate per-target requests against the modes each target declares.
pub fn explicit_requests(
    targets: &[Target],
    mode: Mode,
    assignments: &BTreeMap<String, String>,
) -> Result<BTreeMap<String, Request>> {
    let by_name: BTreeMap<&str, &Target> = targets.iter().map(|t| (t.name.as_str(), t)).collect();
    let wanted = match mode {
        Mode::Release => "release",
        Mode::Revision => "revision",
    };
    let mut requests = BTreeMap::new();
    for (name, value) in assignments {
        let Some(target) = by_name.get(name.as_str()) else {
            return request_error(format!("unknown target: {name}"));
        };
        if !target.accepts.iter().any(|accepted| accepted == wanted) {
            let supported = if target.accepts.is_empty() {
                "automatic updates only".to_string()
            } else {
                target.accepts.join(", ")
            };
            return request_error(format!(
                "{name} does not accept {wanted} requests (supports: {supported})"
            ));
        }
        let request = match mode {
            Mode::Release => Request {
                schema: 1,
                mode,
                target: name.clone(),
                value: value.clone(),
                source: None,
            },
            Mode::Revision if target.backend == Backend::FlakeInput => {
                if crate::support::atoms::Rev::parse(value).is_err() {
                    return request_error(format!(
                        "{name} revision expects a 40-character commit SHA"
                    ));
                }
                Request {
                    schema: 1,
                    mode,
                    target: name.clone(),
                    value: value.to_lowercase(),
                    source: target.source.clone(),
                }
            }
            Mode::Revision => {
                let source = target.source.clone().unwrap_or(Value::Null);
                if source["kind"].as_str() != Some("github") {
                    return request_error(format!("{name} has no GitHub revision source"));
                }
                let (owner, repo_name) = (
                    source["owner"].as_str().unwrap_or_default(),
                    source["repo"].as_str().unwrap_or_default(),
                );
                let rev = parse_revision(name, value, owner, repo_name)?;
                Request {
                    schema: 1,
                    mode,
                    target: name.clone(),
                    value: String::new(),
                    source: Some(serde_json::json!({
                        "kind": "github",
                        "owner": owner,
                        "repo": repo_name,
                        "rev": rev,
                    })),
                }
            }
        };
        requests.insert(name.clone(), request);
    }
    Ok(requests)
}

/// Split the caller's specs into target names and the explicit sources they
/// asked for. The @ value on a target IS its request; an `=` is the retired
/// grammar and gets a pointed correction.
pub fn target_requests(
    targets: &[Target],
    domain: &Domain,
    specs: &[String],
) -> Result<(Vec<String>, BTreeMap<String, Request>)> {
    let mut wanted = Vec::new();
    let mut requests = BTreeMap::new();
    for text in specs {
        if let Some((target_text, source)) = text.split_once('=') {
            return request_error(format!(
                "update expects TARGET@VERSION or TARGET@rev:SHA, not {text:?}; try {target_text}@{source}"
            ));
        }
        let spec = naming::parse(text)?;
        let Some(source) = spec.value.clone() else {
            for name in selected_names(domain, std::slice::from_ref(text))? {
                if !wanted.contains(&name) {
                    wanted.push(name);
                }
            }
            continue;
        };
        let hits = domain.resolve(&spec)?;
        if hits.len() != 1 {
            return request_error(format!(
                "an explicit source takes one target, {} names several",
                spec.render()
            ));
        }
        let name = hits[0].key.clone();
        if requests.contains_key(&name) {
            return request_error(format!("update repeats source for target {name:?}"));
        }
        use crate::support::naming::SourceSpec;
        let (mode, value) = match crate::support::naming::source_spec(source.as_str())? {
            SourceSpec::Revision(rev) => {
                require_merged(targets, &name, rev)?;
                (Mode::Revision, rev.to_string())
            }
            // A tag names one commit; resolving it here means nothing
            // downstream learns a third kind of source.
            SourceSpec::Tag(tag) => (Mode::Revision, resolve_tag(targets, &name, tag)?),
            SourceSpec::Release(value) => (Mode::Release, value.to_string()),
        };
        let assignment = BTreeMap::from([(name.clone(), value)]);
        requests.extend(explicit_requests(targets, mode, &assignment)?);
        if !wanted.contains(&name) {
            wanted.push(name);
        }
    }
    Ok((wanted, requests))
}
