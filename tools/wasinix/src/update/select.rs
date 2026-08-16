//! Which targets a set of specs selects, and the explicit requests they
//! carry. `TARGET@VERSION` and `TARGET@rev:SOURCE` are the whole grammar,
//! shared with `--with`.

use std::collections::BTreeMap;

use serde_json::Value;

use crate::support::error::{request_error, Result};
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
        let (mode, value) = match crate::support::naming::rev_override(source.as_str())? {
            Some(rev) => (Mode::Revision, rev),
            None => (Mode::Release, source.as_str()),
        };
        let assignment = BTreeMap::from([(name.clone(), value.to_string())]);
        requests.extend(explicit_requests(targets, mode, &assignment)?);
        if !wanted.contains(&name) {
            wanted.push(name);
        }
    }
    Ok((wanted, requests))
}
