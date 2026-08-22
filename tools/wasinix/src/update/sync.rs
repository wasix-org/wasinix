use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

use serde::Deserialize;

use crate::support::error::{request_error, Error, Result};
use crate::support::nix::{Invocation, SYSTEM};
use crate::update::flake_lock;

#[derive(Debug, Clone, Copy, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Sort {
    Lexical,
    Numeric,
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AttrList {
    pub input: String,
    pub attr_path: String,
    #[serde(rename = "match")]
    pub pattern: String,
    pub capture: usize,
    pub probe: Option<String>,
    pub sort: Sort,
    pub destination: String,
}

#[derive(Deserialize)]
struct MatchedAttr {
    name: String,
    captures: Vec<Option<String>>,
}

pub struct Outcome {
    pub detail: String,
}

fn valid_component(component: &str) -> bool {
    let mut chars = component.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '\''))
}

fn attr_path(value: &str, field: &str) -> Result<String> {
    let value = value.replace("${system}", SYSTEM);
    if value.contains('$') || !value.split('.').all(valid_component) {
        return request_error(format!(
            "syncAttrList {field} is not a valid attribute path"
        ));
    }
    Ok(value)
}

fn destination(repo: &Path, value: &str) -> Result<PathBuf> {
    let relative = Path::new(value);
    if relative.as_os_str().is_empty()
        || relative
            .components()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        return request_error("syncAttrList destination must be a repo-relative file path");
    }
    Ok(repo.join(relative))
}

fn nix_string(value: &str) -> String {
    let mut rendered = String::from("\"");
    let mut chars = value.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '\\' => rendered.push_str("\\\\"),
            '"' => rendered.push_str("\\\""),
            '$' if chars.peek() == Some(&'{') => rendered.push_str("\\$"),
            '\n' => rendered.push_str("\\n"),
            '\r' => rendered.push_str("\\r"),
            '\t' => rendered.push_str("\\t"),
            c => rendered.push(c),
        }
    }
    rendered.push('"');
    rendered
}

fn probe_expression(probe: Option<&str>) -> Result<String> {
    let Some(probe) = probe else {
        return Ok("true".into());
    };
    let probe = attr_path(probe, "probe")?;
    let probe = probe.split('.').map(nix_string).collect::<Vec<_>>().join(" ");
    Ok(format!(
        "let result = builtins.tryEval (builtins.foldl' \
         (value: name: if builtins.isAttrs value && builtins.hasAttr name value \
         then builtins.getAttr name value else null) \
         (builtins.getAttr entry.name attrs) [{probe}]); \
         in result.success && result.value != null"
    ))
}

fn apply_expression(spec: &AttrList) -> Result<String> {
    let probe = probe_expression(spec.probe.as_deref())?;
    Ok(format!(
        "attrs: builtins.filter (entry: entry.captures != null && ({probe})) \
         (builtins.map (name: {{ inherit name; captures = builtins.match {} name; }}) \
         (builtins.attrNames attrs))",
        nix_string(&spec.pattern)
    ))
}

fn projected_values(spec: &AttrList, matched: Vec<MatchedAttr>) -> Result<Vec<String>> {
    let mut values = BTreeMap::new();
    for entry in matched {
        let value = if spec.capture == 0 {
            entry.name.clone()
        } else {
            entry
                .captures
                .get(spec.capture - 1)
                .and_then(Option::as_ref)
                .cloned()
                .ok_or_else(|| {
                    Error::Request(format!(
                        "syncAttrList match {} has no capture {}",
                        entry.name, spec.capture
                    ))
                })?
        };
        if value.chars().any(char::is_control) {
            return request_error(format!(
                "syncAttrList attribute {} produced a control character",
                entry.name
            ));
        }
        if let Some(previous) = values.insert(value.clone(), entry.name.clone()) {
            return request_error(format!(
                "syncAttrList attributes {previous} and {} both produce {value}",
                entry.name
            ));
        }
    }
    let mut values: Vec<String> = values.into_keys().collect();
    match spec.sort {
        Sort::Lexical => values.sort(),
        Sort::Numeric => {
            let mut numeric = Vec::with_capacity(values.len());
            for value in values {
                let number = value.parse::<u128>().map_err(|_| {
                    Error::Request(format!(
                        "syncAttrList numeric sort cannot order capture {value}"
                    ))
                })?;
                numeric.push((number, value));
            }
            numeric.sort_by(|(left, left_text), (right, right_text)| {
                left.cmp(right).then_with(|| left_text.cmp(right_text))
            });
            values = numeric.into_iter().map(|(_, value)| value).collect();
        }
    }
    Ok(values)
}

fn render(values: &[String]) -> String {
    let body = values
        .iter()
        .map(|value| nix_string(value))
        .collect::<Vec<_>>()
        .join(" ");
    format!("# Generated by wasinix update from a locked flake input.\n[{body}]\n")
}

fn parse_existing(text: &str) -> Result<Vec<String>> {
    let text = text
        .lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .collect::<Vec<_>>()
        .join("\n");
    let bytes = text.as_bytes();
    let mut at = 0;
    let skip_space = |at: &mut usize| {
        while bytes.get(*at).is_some_and(u8::is_ascii_whitespace) {
            *at += 1;
        }
    };
    skip_space(&mut at);
    if bytes.get(at) != Some(&b'[') {
        return request_error("syncAttrList destination is not a Nix string list");
    }
    at += 1;
    let mut values = Vec::new();
    loop {
        skip_space(&mut at);
        if bytes.get(at) == Some(&b']') {
            at += 1;
            break;
        }
        if bytes.get(at) != Some(&b'"') {
            return request_error("syncAttrList destination is not a Nix string list");
        }
        let start = at;
        at += 1;
        let mut escaped = false;
        while let Some(byte) = bytes.get(at) {
            at += 1;
            if escaped {
                escaped = false;
            } else if *byte == b'\\' {
                escaped = true;
            } else if *byte == b'"' {
                break;
            }
        }
        if bytes.get(at.saturating_sub(1)) != Some(&b'"') {
            return request_error("syncAttrList destination has an unterminated string");
        }
        let encoded = std::str::from_utf8(&bytes[start..at])
            .map_err(|_| Error::Request("syncAttrList destination is not UTF-8".into()))?
            .replace("\\${", "\\u0024{");
        let value: String = serde_json::from_str(&encoded).map_err(|source| Error::Json {
            path: "<syncAttrList destination>".into(),
            source,
        })?;
        values.push(value);
    }
    skip_space(&mut at);
    if at != bytes.len() {
        return request_error("syncAttrList destination has content after its list");
    }
    Ok(values)
}

pub fn run(repo: &Path, spec: &AttrList) -> Result<Outcome> {
    if !valid_component(&spec.input) {
        return request_error("syncAttrList input is not a valid flake input name");
    }
    let attr_path = attr_path(&spec.attr_path, "attrPath")?;
    let destination = destination(repo, &spec.destination)?;
    let locked = flake_lock::locked_input(repo, &spec.input)?;
    let flake_ref = flake_lock::exact_ref(&spec.input, &locked)?;
    let value = Invocation::flake("eval", format!("{flake_ref}#{attr_path}"))
        .json()
        .apply(&apply_expression(spec)?)
        .workdir(repo)
        .run_json(&format!("syncing {}", spec.destination))?;
    let matched: Vec<MatchedAttr> =
        crate::support::json::from_value(value, &format!("syncAttrList {}", spec.destination))?;
    let current = projected_values(spec, matched)?;
    let prior_text = crate::support::fs::read_to_string(&destination)?;
    let prior = parse_existing(&prior_text)?;
    let added: Vec<&str> = current
        .iter()
        .filter(|value| !prior.contains(value))
        .map(String::as_str)
        .collect();
    let removed: Vec<&str> = prior
        .iter()
        .filter(|value| !current.contains(value))
        .map(String::as_str)
        .collect();
    let rendered = render(&current);
    let canonicalized = rendered != prior_text;
    if canonicalized {
        crate::support::fs::write_atomic(&destination, rendered.as_bytes())?;
    }
    let detail = if added.is_empty() && removed.is_empty() {
        if canonicalized {
            format!("{}: canonicalized", spec.destination)
        } else {
            format!("{} up to date", spec.destination)
        }
    } else {
        let mut changes = Vec::new();
        if !added.is_empty() {
            changes.push(format!("added {}", added.join(", ")));
        }
        if !removed.is_empty() {
            changes.push(format!("removed {}", removed.join(", ")));
        }
        format!("{}: {}", spec.destination, changes.join("; "))
    };
    Ok(Outcome { detail })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec() -> AttrList {
        AttrList {
            input: "nixpkgs".into(),
            attr_path: "legacyPackages.${system}".into(),
            pattern: "^icu([0-9]+)$".into(),
            capture: 1,
            probe: Some("version".into()),
            sort: Sort::Numeric,
            destination: "versions.nix".into(),
        }
    }

    #[test]
    fn query_uses_the_declared_match_capture_and_probe() {
        let query = apply_expression(&spec()).unwrap();
        assert!(query.contains("builtins.match \"^icu([0-9]+)$\" name"));
        assert!(query.contains("[\"version\"]"));
        assert!(query.contains("builtins.hasAttr name value"));
        assert!(query.contains("builtins.tryEval"));
    }

    #[test]
    fn projections_are_unique_and_numerically_sorted() {
        let matched = ["100", "9", "78"]
            .into_iter()
            .map(|major| MatchedAttr {
                name: format!("icu{major}"),
                captures: vec![Some(major.into())],
            })
            .collect();
        assert_eq!(
            projected_values(&spec(), matched).unwrap(),
            ["9", "78", "100"]
        );
    }

    #[test]
    fn generated_lists_round_trip() {
        let values = vec!["60".into(), "78".into()];
        assert_eq!(parse_existing(&render(&values)).unwrap(), values);
    }

    #[test]
    fn destinations_cannot_escape_the_repo() {
        assert!(destination(Path::new("/repo"), "../versions.nix").is_err());
        assert!(destination(Path::new("/repo"), "/tmp/versions.nix").is_err());
    }
}
