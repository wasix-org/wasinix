//! What can be updated: package-declared updateScripts discovered from the
//! flake, the flake inputs themselves, and the crate-pin set.

use std::collections::BTreeMap;
use std::path::Path;

use serde::Deserialize;
use serde_json::Value;

use crate::support::error::Result;
use crate::support::naming::{self, Domain};
use crate::support::nix::{eval, Flake, SYSTEM};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Backend {
    /// A package's own `passthru.updateScript`.
    UpdateScript,
    /// A `flake.lock` input, which has no package file to carry a script.
    FlakeInput,
    /// The overlay registry's crates.json, re-enumerated from crates.io.
    CratePins,
}

#[derive(Debug, Clone)]
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
            Backend::CratePins => "cargoRegistry.crates".to_string(),
            Backend::UpdateScript => self
                .attr
                .strip_prefix(&format!("legacyPackages.{SYSTEM}."))
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
        attr: format!("legacyPackages.{SYSTEM}.{attr_path}"),
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
    })
}

/// One target per package, deduped across the per-profile attrs.
pub fn discovered_targets(repo: &Path) -> Result<Vec<Target>> {
    let declared = eval(&Flake::default(), "updateScripts", None)?;
    // Ordered by attribute, deduped by name: the first attr declaring a name
    // wins, and a package's position in the run follows where it was found.
    let mut targets: Vec<Target> = Vec::new();
    let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    for (attr, value) in declared.as_object().into_iter().flatten() {
        let target = declared_target(repo, attr, value)?;
        if !seen.insert(target.name.clone()) {
            continue;
        }
        targets.push(target);
    }
    Ok(targets)
}

pub struct Hook {
    pub name: String,
    pub command: Vec<String>,
    pub command_drv_paths: Vec<String>,
}

/// Package-declared re-syncs, deduped by command across the profile attrs.
pub fn discovered_hooks() -> Result<Vec<Hook>> {
    let declared = eval(&Flake::default(), "retentionHooks", None)?;
    let mut hooks: BTreeMap<Vec<String>, (String, Vec<String>)> = BTreeMap::new();
    for (attr, value) in declared.as_object().into_iter().flatten() {
        let context = format!("retentionHooks.{attr}");
        let command: Vec<String> =
            crate::support::json::from_value(value["command"].clone(), &context)?;
        let drvs: Vec<String> =
            crate::support::json::from_value(value["commandDrvPaths"].clone(), &context)?;
        hooks
            .entry(command)
            .or_insert_with(|| (attr.rsplit('.').next().unwrap_or(attr).to_string(), drvs));
    }
    Ok(hooks
        .into_iter()
        .map(|(command, (name, command_drv_paths))| Hook {
            name,
            command,
            command_drv_paths,
        })
        .collect())
}

pub fn all_targets(repo: &Path) -> Result<Vec<Target>> {
    let mut targets = discovered_targets(repo)?;
    let lock_path = repo.join("flake.lock");
    let lock: Value = crate::support::json::read(&lock_path)?;
    let root = lock["root"].as_str().unwrap_or("root");
    for mut target in builtin_targets() {
        if target.backend == Backend::FlakeInput {
            let node = lock["nodes"][root]["inputs"][&target.input]
                .as_str()
                .unwrap_or(&target.input);
            let locked = &lock["nodes"][node]["locked"];
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
    Ok(targets)
}

/// The pins a caller can name. A pin is addressed where it lives, which is
/// the attr its updateScript is declared on, or `inputs.<name>` for a flake
/// input. Its short name stays as an alias: `toolchain.llvm.clang` is where
/// the llvm pin lives, and `llvm` is what it is called.
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
