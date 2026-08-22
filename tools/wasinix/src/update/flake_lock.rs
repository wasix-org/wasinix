use std::path::Path;

use serde_json::Value;

use crate::support::error::{request_error, Error, Result};

fn node_reference(lock: &Value, reference: &Value) -> Result<String> {
    if let Some(node) = reference.as_str() {
        return Ok(node.to_string());
    }
    let path = reference
        .as_array()
        .ok_or_else(|| Error::Request("invalid flake.lock input reference".into()))?;
    let root = lock["root"]
        .as_str()
        .ok_or_else(|| Error::Request("flake.lock has no root node".into()))?;
    let mut node = root.to_string();
    for component in path {
        let component = component.as_str().ok_or_else(|| {
            Error::Request("flake.lock followed-input paths must contain strings".into())
        })?;
        let next = &lock["nodes"][&node]["inputs"][component];
        node = node_reference(lock, next)?;
    }
    Ok(node)
}

pub fn locked_input(repo: &Path, input: &str) -> Result<Value> {
    let path = repo.join("flake.lock");
    let lock: Value = crate::support::json::read(&path)?;
    let root = lock["root"]
        .as_str()
        .ok_or_else(|| Error::Request("flake.lock has no root node".into()))?;
    let reference = &lock["nodes"][root]["inputs"][input];
    if reference.is_null() {
        return request_error(format!("flake.lock root has no {input} input"));
    }
    let node = node_reference(&lock, reference)?;
    let locked = &lock["nodes"][&node]["locked"];
    if !locked.is_object() {
        return request_error(format!("flake.lock input {input} has no locked source"));
    }
    Ok(locked.clone())
}

pub fn exact_ref(input: &str, locked: &Value) -> Result<String> {
    let field = |name: &str| {
        locked[name]
            .as_str()
            .ok_or_else(|| Error::Request(format!("flake.lock input {input} has no locked {name}")))
    };
    let encode = |value: &str| {
        value
            .bytes()
            .map(|byte| {
                if byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'.' | b'_' | b'~') {
                    (byte as char).to_string()
                } else {
                    format!("%{byte:02X}")
                }
            })
            .collect::<String>()
    };
    let mut query = vec![format!("narHash={}", encode(field("narHash")?))];
    if let Some(dir) = locked["dir"].as_str() {
        query.push(format!("dir={}", encode(dir)));
    }
    if locked["submodules"].as_bool().unwrap_or(false) {
        query.push("submodules=1".into());
    }
    let query = query.join("&");
    match field("type")? {
        kind @ ("github" | "gitlab" | "sourcehut") => Ok(format!(
            "{kind}:{}/{}/{}?{query}",
            field("owner")?,
            field("repo")?,
            field("rev")?
        )),
        "git" => {
            let separator = if field("url")?.contains('?') {
                '&'
            } else {
                '?'
            };
            Ok(format!(
                "git+{}{separator}rev={}&{query}",
                field("url")?,
                field("rev")?
            ))
        }
        kind => request_error(format!(
            "flake.lock input {input} uses unsupported locked source type {kind}"
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn followed_inputs_resolve_to_their_locked_node() {
        let scratch = crate::support::fs::Scratch::create("wasinix-lock-test").unwrap();
        crate::support::fs::write(
            &scratch.path().join("flake.lock"),
            br#"{
              "root": "root",
              "nodes": {
                "root": { "inputs": { "alias": ["owner", "dep"], "owner": "owner" } },
                "owner": { "inputs": { "dep": "locked" } },
                "locked": { "locked": { "type": "github", "rev": "abc" } }
              }
            }"#,
        )
        .unwrap();
        assert_eq!(
            locked_input(scratch.path(), "alias").unwrap()["rev"],
            "abc"
        );
    }

    #[test]
    fn exact_refs_carry_the_lock_hash() {
        let reference = exact_ref(
            "nixpkgs",
            &serde_json::json!({
                "type": "github",
                "owner": "NixOS",
                "repo": "nixpkgs",
                "rev": "abc",
                "narHash": "sha256-a+b/="
            }),
        )
        .unwrap();
        assert_eq!(
            reference,
            "github:NixOS/nixpkgs/abc?narHash=sha256-a%2Bb%2F%3D"
        );
    }
}
