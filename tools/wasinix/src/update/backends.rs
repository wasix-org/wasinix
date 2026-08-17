//! Running one target's bump, per backend.

use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

use crate::support::error::{request_error, Result};
use crate::support::format::short_rev;
use crate::support::nix::eval_installable;
use crate::support::ui;
use crate::update::targets::{Backend, Target};
use crate::update::{Mode, Request, REQUEST_ENV};

/// The crate-pins backend reports its state rather than a version.
static CRATE_STATE: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^(\d+ pins) \(0 fetched\)$").unwrap());

fn resolve_command(repo: &Path, command: &[String]) -> Vec<String> {
    let mut cmd = command.to_vec();
    // Repo-relative script commands run from the checkout; store paths and
    // bare tool names pass through.
    if cmd[0].contains('/') && !cmd[0].starts_with('/') {
        cmd[0] = repo.join(&cmd[0]).to_string_lossy().to_string();
    }
    cmd
}

/// A collected command referencing store paths (a wrapper script, the
/// nix-update argv it is handed) may not be realised here; the declaration
/// carries the drv paths to build them from.
pub(crate) fn realise_command(name: &str, cmd: &[String], drvs: &[String]) -> Result<()> {
    if !cmd
        .iter()
        .any(|arg| arg.starts_with("/nix/store/") && !Path::new(arg).exists())
    {
        return Ok(());
    }
    if drvs.is_empty() {
        return request_error(format!(
            "{name}: command references unrealised store paths and the declaration \
             carries no derivations to realise them"
        ));
    }
    crate::support::nix::Invocation::tool("nix-store")
        .args(["--realise"])
        .operands(drvs.iter().cloned())
        .checked_output("realising the update script")?;
    Ok(())
}

pub(crate) fn run_capturing(
    repo: &Path,
    cmd: &[String],
    env: &[(String, String)],
) -> Result<(i32, String, String)> {
    let mut command = Command::new(&cmd[0]);
    command.args(&cmd[1..]).current_dir(repo);
    for (key, value) in env {
        command.env(key, value);
    }
    crate::support::tools::log(&command);
    let output = crate::support::tools::output(&mut command)?;
    Ok((
        output.status.code().unwrap_or(1),
        String::from_utf8_lossy(&output.stdout).to_string(),
        String::from_utf8_lossy(&output.stderr).to_string(),
    ))
}

pub(crate) fn echo(stdout: &str) {
    for line in stdout.trim().lines() {
        ui::note(format!("  {line}"));
    }
}

/// nix-update prints an early "Update a -> b in file" line, so the outcome is
/// the last line that looks like one; a malformed line is skipped, never a
/// reason to lose the ones before it.
pub(crate) fn outcome_from(stdout: &str) -> Option<String> {
    for line in stdout.trim().lines().rev() {
        if let Some((before, rest)) = line.rsplit_once(" -> ") {
            let Some(before) = before.split_whitespace().last() else {
                continue;
            };
            let after = rest
                .split_once(" in /")
                .map(|(after, _)| after)
                .unwrap_or(rest)
                .trim();
            if before.is_empty() || after.is_empty() {
                continue;
            }
            return Some(format!("{before} -> {after}"));
        }
    }
    None
}

/// Say which version a target stayed on. The backends report only that
/// nothing moved, and "up to date" alone leaves a reader guessing what it is
/// up to date at.
pub fn normalize_outcome(target: &Target, outcome: String, changed: bool) -> String {
    if target.backend == Backend::CratePins && !changed {
        if let Some(pins) = CRATE_STATE.captures(&outcome) {
            return format!("up to date ({})", &pins[1]);
        }
    }
    if outcome == "up to date" && !target.version.is_empty() {
        let version = if target.backend == Backend::FlakeInput {
            short_rev(&target.version).to_string()
        } else {
            target.version.clone()
        };
        return format!("up to date ({version})");
    }
    outcome
}

/// Changelogs of the targets that moved, read in one evaluation after every
/// bump landed, so a url spelling the version points at the release that
/// landed. Advisory, but a failed lookup is said once, not swallowed.
pub fn changelogs(targets: &[&Target]) -> BTreeMap<String, String> {
    let addressed: Vec<&&Target> = targets
        .iter()
        .filter(|target| target.backend == Backend::UpdateScript)
        .collect();
    if addressed.is_empty() {
        return BTreeMap::new();
    }
    let mut selected = String::from("p: {");
    for target in &addressed {
        let segments = crate::support::naming::split(&target.address()).unwrap_or_default();
        let list = segments
            .iter()
            .map(|segment| serde_json::Value::String(segment.clone()).to_string())
            .collect::<Vec<_>>()
            .join(" ");
        selected += &format!(
            "{} = (let r = builtins.tryEval ((builtins.foldl' (a: k: a.${{k}}) p [{list}]).meta.changelog or null); in if r.success then r.value else null);",
            serde_json::Value::String(target.name.clone()),
        );
    }
    selected += "}";
    let value = match eval_installable(
        &format!(".#legacyPackages.{}", crate::support::nix::SYSTEM),
        Some(&selected),
    ) {
        Ok(value) => value,
        Err(error) => {
            ui::warning(format!("changelog lookup failed: {error}"));
            return BTreeMap::new();
        }
    };
    value
        .as_object()
        .into_iter()
        .flatten()
        .filter_map(|(name, url)| url.as_str().map(|url| (name.clone(), url.to_string())))
        .collect()
}

fn run_update_script(
    repo: &Path,
    target: &Target,
    request: Option<&Request>,
) -> Result<Option<String>> {
    let mut cmd = resolve_command(repo, &target.command);
    // A target that declares nix-update directly has no wrapper to read the
    // request, so the release is applied to its argv here. Without this, a
    // package accepting release requests would run an ordinary channel update
    // and report success having ignored the version asked for.
    if Path::new(&cmd[0])
        .file_name()
        .is_some_and(|name| name == "nix-update")
    {
        cmd = crate::update::request::nix_update_argv(&cmd, request)?;
    }
    realise_command(&target.name, &cmd, &target.command_drv_paths)?;
    let mut env = vec![("UPDATE_NIX_ATTR_PATH".to_string(), target.attr.clone())];
    if !target.file.is_empty() {
        env.push(("UPDATE_NIX_SOURCE_FILE".to_string(), target.file.clone()));
    }
    if let Some(request) = request {
        env.push((
            REQUEST_ENV.to_string(),
            serde_json::to_string(request).map_err(|source| {
                crate::support::error::Error::Json {
                    path: format!("<{REQUEST_ENV}>").into(),
                    source,
                }
            })?,
        ));
    }
    let (code, stdout, stderr) = run_capturing(repo, &cmd, &env)?;
    ui::raw(&stderr);
    echo(&stdout);
    if code != 0 {
        // A --version-regex that excludes every available tag means there is
        // nothing to bump, not a broken updater.
        if stderr.contains("No version matched the regex") {
            let found: String = stderr
                .rsplit_once("versions were found:")
                .map(|(_, rest)| rest.split_whitespace().collect::<Vec<_>>().join(" "))
                .unwrap_or_default();
            return Ok(Some(format!(
                "up to date (no release matches the version regex; found: {found})"
            )));
        }
        let detail = if stderr.trim().is_empty() {
            stdout.trim()
        } else {
            stderr.trim()
        };
        return request_error(format!("{} exited {code}:\n{detail}", target.command[0]));
    }
    Ok(outcome_from(&stdout))
}

fn flake_input_rev(repo: &Path, input: &str) -> Result<String> {
    let lock: Value = crate::support::json::read(&repo.join("flake.lock"))?;
    let locked = &lock["nodes"][input]["locked"];
    Ok(locked["rev"]
        .as_str()
        .or_else(|| locked["ref"].as_str())
        .unwrap_or_default()
        .to_string())
}

pub(crate) fn flake_override_ref(source: &Value, rev: &str) -> Result<String> {
    match source["kind"].as_str() {
        Some("github") => Ok(format!(
            "github:{}/{}/{rev}",
            source["owner"].as_str().unwrap_or_default(),
            source["repo"].as_str().unwrap_or_default()
        )),
        Some("git") => {
            let url = source["url"].as_str().unwrap_or_default();
            let prefix = if url.starts_with("git+") { "" } else { "git+" };
            let separator = if url.contains('?') { '&' } else { '?' };
            let submodules = if source["submodules"].as_bool() == Some(true) {
                "&submodules=1"
            } else {
                ""
            };
            Ok(format!("{prefix}{url}{separator}rev={rev}{submodules}"))
        }
        _ => request_error("flake input has no Git revision source"),
    }
}

fn update_flake_input(
    repo: &Path,
    target: &Target,
    request: Option<&Request>,
) -> Result<Option<String>> {
    let before = flake_input_rev(repo, &target.input)?;
    let requested = request.map(|request| request.value.as_str());
    let override_ref = match request {
        None => None,
        Some(request) if request.mode != Mode::Revision => {
            return request_error(format!("{} only accepts revision requests", target.name))
        }
        Some(request) => {
            let source = request.source.as_ref().unwrap_or(&Value::Null);
            Some(flake_override_ref(source, &request.value).map_err(|_| {
                crate::support::error::Error::Request(format!(
                    "{} has no Git revision source",
                    target.name
                ))
            })?)
        }
    };
    let mut command = vec!["nix".into(), "flake".into()];
    if let Some(reference) = &override_ref {
        command.extend([
            "lock".into(),
            "--override-input".into(),
            target.input.clone(),
            reference.clone(),
        ]);
    } else {
        command.extend(["update".into(), target.input.clone()]);
    }
    let (code, _, stderr) = run_capturing(repo, &command, &[])?;
    ui::raw(&stderr);
    if code != 0 {
        return request_error(format!("nix flake pin update exited {code}"));
    }
    let after = flake_input_rev(repo, &target.input)?;
    if requested.is_some_and(|rev| rev != after) {
        return request_error(format!(
            "{} resolved requested revision {} to {after}",
            target.name,
            requested.unwrap_or_default()
        ));
    }
    let outcome = if before == after {
        "up to date".to_string()
    } else {
        format!("{} -> {}", short_rev(&before), short_rev(&after))
    };
    ui::note(format!("  {outcome}"));
    Ok(Some(outcome))
}

fn update_crate_pins(repo: &Path, request: Option<&Request>) -> Result<Option<String>> {
    if request.is_some() {
        return request_error("cargo-registry cannot materialize an explicit request");
    }
    let line = crate::update::cratepins::run(repo, false)?;
    ui::note(format!("  {line}"));
    Ok(line
        .split_once(':')
        .map(|(_, rest)| rest.trim().to_string()))
}

pub fn run_backend(
    repo: &Path,
    target: &Target,
    request: Option<&Request>,
) -> Result<Option<String>> {
    match target.backend {
        Backend::UpdateScript => run_update_script(repo, target, request),
        Backend::FlakeInput => update_flake_input(repo, target, request),
        Backend::CratePins => update_crate_pins(repo, request),
    }
}
