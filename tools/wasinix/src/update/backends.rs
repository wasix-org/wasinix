//! Running one target's bump, per backend.

use std::collections::BTreeMap;
use std::path::Path;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::Value;

use crate::support::error::{Result, request_error};
use crate::support::format::short_rev;
use crate::support::nix::eval_installable;
use crate::support::ui;
use crate::update::targets::{Backend, Target};
use crate::update::upstream::Release;
use crate::update::{Mode, REQUEST_ENV, Request};

/// What a backend did: the outcome line the ChangeSet renders, and any notes
/// the move itself raised. A note is the backend's own observation about the
/// bump, distinct from the package-declared notes the fold collects later.
#[derive(Debug, Default)]
pub struct Outcome {
    pub summary: Option<String>,
    pub notes: Vec<String>,
}

impl Outcome {
    fn summary(summary: String) -> Outcome {
        Outcome {
            summary: Some(summary),
            notes: Vec::new(),
        }
    }
}

impl From<Option<String>> for Outcome {
    fn from(summary: Option<String>) -> Outcome {
        Outcome {
            summary,
            notes: Vec::new(),
        }
    }
}

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
    let mut command = crate::support::tools::Process::new(&cmd[0]);
    command.args(&cmd[1..]).current_dir(repo);
    for (key, value) in env {
        command.env(key, value);
    }
    let output = command.capture()?;
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
        &crate::support::nix::active_project_installable(""),
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

/// Run a declared nix-update command with the driver's request applied,
/// streaming its output. Update scripts handed the nix-update argv re-enter
/// the driver through `wasinix update nix-update -- <argv>` so the request
/// contract lives here, not in each script.
pub fn run_nix_update(repo: &Path, argv: &[String]) -> Result<i32> {
    if argv.is_empty() {
        return request_error("no nix-update command passed");
    }
    let request = crate::update::request::current(None)?;
    let argv = crate::update::request::nix_update_argv(argv, request.as_ref())?;
    let mut command = crate::support::tools::Process::new(&argv[0]);
    command.args(&argv[1..]).current_dir(repo);
    let status = command.run()?;
    Ok(status.code().unwrap_or(1))
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

/// A flake reference that names the release tag as well as its commit, so
/// `flake.lock` records which release the pin is rather than an anonymous
/// revision. The tag is a ref, not a substitute for the rev: the rev is what
/// pins, and the ref only carries the identity.
fn flake_release_ref(source: &Value, tag: &str, rev: &str) -> Result<String> {
    let reference = flake_override_ref(source, rev)?;
    let separator = if reference.contains('?') { '&' } else { '?' };
    Ok(format!("{reference}{separator}ref=refs/tags/{tag}"))
}

/// The release a release-tracked pin should move to, if upstream has one
/// newer than the pin. `None` leaves the pin where it is, which is what a
/// quiet upstream and a pin already at the newest release both mean.
fn release_move(target: &Target, before: &str) -> Result<Option<(Release, Option<String>)>> {
    let mirror = release_mirror(target)?;
    let releases = crate::update::upstream::releases(&mirror)?;
    let current = crate::update::upstream::identity(&mirror, before, &releases)?;
    let Some(release) = crate::update::upstream::newer_than(&releases, current) else {
        ui::note(format!("  {current} is the newest release"));
        return Ok(None);
    };
    // Whether the release still contains what the outgoing pin carried. A
    // pin deliberately held ahead of its release, or a release cut off a
    // release branch, makes this false: the move is still the right one, but
    // it drops commits and must not land unreviewed.
    let dropped = crate::update::upstream::commits_not_in(&mirror, before, &release.rev)?;
    let note = (dropped > 0).then(|| {
        format!(
            "{} {current} -> {} does not contain the outgoing pin {}: {dropped} commit(s) it \
             carried are not in the release. Confirm nothing needed is lost before merging.",
            target.name,
            release.version,
            short_rev(before),
        )
    });
    Ok(Some((release.clone(), note)))
}

/// The release an explicit release request names.
fn requested_release(target: &Target, value: &str) -> Result<Release> {
    let Some(version) = crate::update::upstream::Version::parse(value) else {
        return request_error(format!(
            "{}: {value:?} is not a release version",
            target.name
        ));
    };
    let mirror = release_mirror(target)?;
    let releases = crate::update::upstream::releases(&mirror)?;
    match crate::update::upstream::release_named(&releases, version) {
        Some(release) => Ok(release.clone()),
        None => request_error(format!("{}: no release {version} upstream", target.name)),
    }
}

fn release_mirror(target: &Target) -> Result<std::path::PathBuf> {
    let Some(repository) = target
        .source
        .as_ref()
        .and_then(crate::update::upstream::source_repository)
    else {
        return request_error(format!(
            "{} tracks releases but declares no git source",
            target.name
        ));
    };
    crate::update::upstream::mirror(&repository)
}

fn update_flake_input(repo: &Path, target: &Target, request: Option<&Request>) -> Result<Outcome> {
    let before = flake_input_rev(repo, &target.input)?;
    let source = || {
        request
            .and_then(|request| request.source.clone())
            .or_else(|| target.source.clone())
            .unwrap_or(Value::Null)
    };
    let mut notes = Vec::new();
    // What the lock must hold afterwards, for the request kinds that name a
    // commit. A resolution that lands somewhere else is a failure, not a
    // surprise the caller has to notice in the receipt.
    let mut expected: Option<String> = None;
    let override_ref = match request {
        Some(request) if request.mode == Mode::Release => {
            if !target.release_line {
                return request_error(format!("{} only accepts revision requests", target.name));
            }
            let release = requested_release(target, &request.value)?;
            expected = Some(release.rev.clone());
            Some(flake_release_ref(&source(), &release.tag, &release.rev)?)
        }
        Some(request) if request.mode != Mode::Revision => {
            return request_error(format!("{} only accepts revision requests", target.name));
        }
        Some(request) => {
            expected = Some(request.value.clone());
            Some(flake_override_ref(&source(), &request.value).map_err(|_| {
                crate::support::error::Error::Request(format!(
                    "{} has no Git revision source",
                    target.name
                ))
            })?)
        }
        // A release-tracked pin never follows its ref. Advancing to the
        // newest release is the whole rule; anything else would put the pin
        // back on whatever the branch happened to hold.
        None if target.release_line => match release_move(target, &before)? {
            None => {
                let outcome = "up to date".to_string();
                ui::note(format!("  {outcome}"));
                return Ok(Outcome::summary(outcome));
            }
            Some((release, note)) => {
                notes.extend(note);
                expected = Some(release.rev.clone());
                Some(flake_release_ref(&source(), &release.tag, &release.rev)?)
            }
        },
        None => None,
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
    if expected.as_deref().is_some_and(|rev| rev != after) {
        return request_error(format!(
            "{} resolved requested revision {} to {after}",
            target.name,
            expected.unwrap_or_default()
        ));
    }
    let outcome = if before == after {
        "up to date".to_string()
    } else {
        format!("{} -> {}", short_rev(&before), short_rev(&after))
    };
    ui::note(format!("  {outcome}"));
    for note in &notes {
        ui::warning(note);
    }
    Ok(Outcome {
        summary: Some(outcome),
        notes,
    })
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

pub fn run_backend(repo: &Path, target: &Target, request: Option<&Request>) -> Result<Outcome> {
    match target.backend {
        Backend::UpdateScript => run_update_script(repo, target, request).map(Outcome::from),
        Backend::FlakeInput => update_flake_input(repo, target, request),
        Backend::CratePins => update_crate_pins(repo, request).map(Outcome::from),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The tag rides along as a ref so the lock records which release the pin
    /// is; the rev is still what pins, and submodules must survive both.
    #[test]
    fn a_release_reference_carries_the_tag_beside_the_revision() {
        let source = serde_json::json!({
            "kind": "git",
            "url": "https://github.com/wasmerio/wasmer",
            "submodules": true,
        });
        let rev = "32b50f8b600efa8e2d5f88593c453139bf1ca222";
        assert_eq!(
            flake_release_ref(&source, "v7.4.0", rev).unwrap(),
            format!(
                "git+https://github.com/wasmerio/wasmer?rev={rev}&submodules=1&ref=refs/tags/v7.4.0"
            )
        );
    }

    #[test]
    fn a_github_release_reference_still_names_the_tag() {
        let source = serde_json::json!({"kind": "github", "owner": "o", "repo": "r"});
        assert_eq!(
            flake_release_ref(&source, "v1.2.3", "abc").unwrap(),
            "github:o/r/abc?ref=refs/tags/v1.2.3"
        );
    }
}
