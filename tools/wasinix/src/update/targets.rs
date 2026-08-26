//! What can be updated: package-declared updateScripts discovered from the
//! flake, the flake inputs themselves, and the crate-pin set.

use std::collections::BTreeMap;
use std::path::Path;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::support::error::{request_error, Result};
use crate::support::naming::{self, Domain};
use crate::support::nix::project_attr;

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Backend {
    /// A package's own `passthru.updateScript`.
    UpdateScript,
    /// A `flake.lock` input, which has no package file to carry a script.
    FlakeInput,
    /// The overlay registry's crates.json, re-enumerated from crates.io.
    CratePins,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub name: String,
    pub backend: Backend,
    pub input: String,
    pub attr: String,
    /// The version pinned before the run, for reporting one that did not move.
    pub version: String,
    pub command: Vec<String>,
    pub command_drv_paths: Vec<String>,
    /// Repo-relative pin file, from meta.position.
    pub file: String,
    pub accepts: Vec<String>,
    pub source: Option<Value>,
    #[serde(default)]
    pub ownership: Ownership,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Ownership {
    pub assignees: Vec<Maintainer>,
    pub reviewers: Vec<Maintainer>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Maintainer {
    pub github: String,
}

impl Target {
    fn flake(name: &str) -> Target {
        Target {
            name: name.to_string(),
            backend: Backend::FlakeInput,
            input: name.to_string(),
            attr: String::new(),
            version: String::new(),
            command: Vec::new(),
            command_drv_paths: Vec::new(),
            file: String::new(),
            accepts: Vec::new(),
            source: None,
            ownership: Ownership::default(),
        }
    }

    pub fn detail(&self) -> String {
        match self.backend {
            Backend::FlakeInput => self.input.clone(),
            _ => self.command.join(" "),
        }
    }

    /// Where the pin lives, as an address.
    pub fn address(&self) -> String {
        match self.backend {
            Backend::FlakeInput => format!("inputs.{}", self.input),
            Backend::CratePins => "artifacts.registry.cargo-registry.crates".to_string(),
            Backend::UpdateScript => self
                .attr
                .strip_prefix(&format!("{}.", project_attr("")))
                .unwrap_or(&self.attr)
                .to_string(),
        }
    }

    pub fn backend_name(&self) -> &'static str {
        match self.backend {
            Backend::UpdateScript => "updateScript",
            Backend::FlakeInput => "flake",
            Backend::CratePins => "cargo-registry",
        }
    }
}

/// Flake inputs are their own targets so `update nixpkgs` works like a
/// package; the crate-pin set is named for the file it regenerates.
fn builtin_targets() -> Vec<Target> {
    let mut targets: Vec<Target> = ["nixpkgs", "wasmer", "treefmt-nix", "ghc-wasm-meta"]
        .into_iter()
        .map(Target::flake)
        .collect();
    targets.push(Target {
        name: "cargo-registry".into(),
        backend: Backend::CratePins,
        ..Target::flake("cargo-registry")
    });
    targets
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Declaration {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    version: Option<String>,
    #[serde(default)]
    position: Option<String>,
    #[serde(default)]
    attr_path: Option<String>,
    command: Vec<String>,
    #[serde(default)]
    command_drv_paths: Vec<String>,
    #[serde(default)]
    accepts: Vec<String>,
    #[serde(default)]
    source: Option<Value>,
    #[serde(default)]
    ownership: Ownership,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct PostUpdateHook {
    pub name: String,
    pub action: PostUpdateAction,
    pub version: String,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum PostUpdateAction {
    Command {
        command: Vec<String>,
        command_drv_paths: Vec<String>,
    },
    SyncAttrList(crate::update::sync::AttrList),
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PostUpdateDeclaration {
    action: PostUpdateAction,
    version: String,
}

pub(crate) fn declared_post_update_hook(attr: &str, value: &Value) -> Result<PostUpdateHook> {
    let declaration: PostUpdateDeclaration =
        crate::support::json::from_value(value.clone(), &format!("postUpdateHooks.{attr}"))?;
    Ok(PostUpdateHook {
        name: attr.rsplit('.').next().unwrap_or(attr).to_string(),
        action: declaration.action,
        version: declaration.version,
    })
}

/// meta.position under a flake evaluation is inside the source store copy.
fn repo_relative(path: &str, repo: &Path) -> String {
    if let Some(rest) = path
        .strip_prefix("/nix/store/")
        .and_then(|rest| rest.split_once('/'))
    {
        return rest.1.to_string();
    }
    Path::new(path)
        .strip_prefix(repo)
        .map(|rest| rest.to_string_lossy().to_string())
        .unwrap_or_else(|_| path.to_string())
}

/// One collected declaration as a target; the flake emits camelCase keys.
pub(crate) fn declared_target(repo: &Path, attr: &str, value: &Value) -> Result<Target> {
    let declaration: Declaration =
        crate::support::json::from_value(value.clone(), &format!("updateScripts.{attr}"))?;
    let name = declaration
        .name
        .unwrap_or_else(|| attr.rsplit('.').next().unwrap_or(attr).to_string());
    // attrPath names the declared target (an unwrapped package behind a
    // wrapper), else the attr the declaration was found on.
    let attr_path = declaration.attr_path.unwrap_or_else(|| attr.to_string());
    Ok(Target {
        name,
        backend: Backend::UpdateScript,
        input: String::new(),
        attr: project_attr(&attr_path),
        version: declaration.version.unwrap_or_default(),
        command: declaration.command,
        command_drv_paths: declaration.command_drv_paths,
        file: declaration
            .position
            .as_deref()
            .and_then(|pos| pos.rsplit_once(':').map(|(file, _)| file))
            .map(|file| repo_relative(file, repo))
            .unwrap_or_default(),
        accepts: declaration.accepts,
        source: declaration.source,
        ownership: declaration.ownership,
    })
}

/// One target per pin. Declarations are ordered by attribute; the first attr
/// declaring a name wins. A wrapper and its unwrapped package (or the same
/// package under several profiles) declare the same script against the same
/// file, which is one pin and one target, not one per spelling.
pub(crate) fn dedupe(declared: Vec<Target>) -> Result<Vec<Target>> {
    let mut targets: Vec<Target> = Vec::new();
    let mut names: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut pins: std::collections::BTreeSet<(String, Vec<String>)> =
        std::collections::BTreeSet::new();
    let mut ownership = BTreeMap::new();
    for target in declared {
        if let Some(previous) = ownership.insert(target.name.clone(), target.ownership.clone()) {
            if previous != target.ownership {
                return request_error(format!(
                    "update target {} has conflicting ownership declarations",
                    target.name
                ));
            }
        }
        if !target.file.is_empty() && !pins.insert((target.file.clone(), target.command.clone())) {
            continue;
        }
        if !names.insert(target.name.clone()) {
            continue;
        }
        targets.push(target);
    }
    Ok(targets)
}

pub fn discovered_targets(repo: &Path, declared: &Value) -> Result<Vec<Target>> {
    let mut targets: Vec<Target> = Vec::new();
    for (attr, value) in declared.as_object().into_iter().flatten() {
        targets.push(declared_target(repo, attr, value)?);
    }
    dedupe(targets)
}

/// Package-declared post-update operations, deduped across profile attrs.
pub fn discovered_post_update_hooks(declared: &Value) -> Result<Vec<PostUpdateHook>> {
    let mut hooks: BTreeMap<String, PostUpdateHook> = BTreeMap::new();
    for (attr, value) in declared.as_object().into_iter().flatten() {
        let hook = declared_post_update_hook(attr, value)?;
        let name = hook.name.clone();
        if let Some(previous) = hooks.insert(name.clone(), hook.clone()) {
            if previous != hook {
                return request_error(format!(
                    "postUpdateHooks.{name} differs across package sets"
                ));
            }
        }
    }
    Ok(hooks.into_values().collect())
}

pub fn all_targets(
    repo: &Path,
    snapshot: &crate::update::snapshot::Snapshot,
) -> Result<Vec<Target>> {
    let mut targets = discovered_targets(repo, &snapshot.update_scripts)?;
    for mut target in builtin_targets() {
        if target.backend == Backend::FlakeInput {
            let locked = crate::update::flake_lock::locked_input(repo, &target.input)?;
            target.version = locked["rev"].as_str().unwrap_or_default().to_string();
            target.source = match locked["type"].as_str() {
                Some("github") => Some(serde_json::json!({
                    "kind": "github",
                    "owner": locked["owner"],
                    "repo": locked["repo"],
                })),
                Some("git") => Some(serde_json::json!({
                    "kind": "git",
                    "url": locked["url"],
                    "submodules": locked["submodules"].as_bool().unwrap_or(false),
                })),
                _ => None,
            };
            if target.source.is_some() && !target.version.is_empty() {
                target.accepts.push("revision".into());
            }
        }
        targets.push(target);
    }
    // Discovery dedupes within itself, but a declared name can still collide
    // with a builtin; two targets answering to one name would race the same
    // update branch.
    let mut names = std::collections::BTreeSet::new();
    for target in &targets {
        if !names.insert(&target.name) {
            return crate::support::error::request_error(format!(
                "two update targets are named {}; give one declaration a distinct name",
                target.name
            ));
        }
    }
    crate::support::completions::record(
        "update-targets",
        targets.iter().map(|target| target.name.as_str()),
    );
    Ok(targets)
}

/// The pins a caller can name. A pin is addressed where it lives, which is
/// the attr its updateScript is declared on, or `inputs.<name>` for a flake
/// input. Its short name stays as an alias.
pub fn domain(targets: &[Target]) -> Domain {
    let mut domain = Domain::new("wasinix update list");
    for target in targets {
        let aliases = vec![target.name.clone()];
        let path = naming::split(&target.address()).unwrap_or_else(|_| vec![target.name.clone()]);
        let axis = naming::axis_of(&path);
        domain.add_path(path, &target.name, axis, aliases);
    }
    domain
}
