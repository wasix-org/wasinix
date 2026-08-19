//! The process environment, read here and nowhere else. Every variable has a
//! named accessor carrying its parse rule, so a new variable cannot be read
//! without declaring it here; a malformed value is a loud request error,
//! never a silent default.

use std::path::PathBuf;
use std::time::Duration;

use crate::support::error::{request_error, Result};

fn text(name: &str) -> Result<Option<String>> {
    match std::env::var(name) {
        Ok(value) => Ok(Some(value)),
        Err(std::env::VarError::NotPresent) => Ok(None),
        Err(std::env::VarError::NotUnicode(shown)) => {
            request_error(format!("${name} is not unicode: {shown:?}"))
        }
    }
}

fn optional(name: &str) -> Result<Option<String>> {
    Ok(text(name)?.filter(|value| !value.is_empty()))
}

fn positive(name: &str) -> Result<Option<usize>> {
    match text(name)? {
        None => Ok(None),
        Some(value) => match value.parse::<usize>() {
            Ok(parsed) if parsed > 0 => Ok(Some(parsed)),
            _ => request_error(format!(
                "${name} must be a positive integer, got \"{value}\""
            )),
        },
    }
}

fn duration_secs(name: &str) -> Result<Option<Duration>> {
    Ok(positive(name)?.map(|secs| Duration::from_secs(secs as u64)))
}

/// A boolean env var: the usual truthy/falsy spellings, case-insensitive.
/// Unset is false; an unrecognized value is a request error rather than a
/// silent guess.
fn flag(name: &str) -> Result<bool> {
    let Some(value) = text(name)? else {
        return Ok(false);
    };
    match value.trim().to_ascii_lowercase().as_str() {
        "" | "0" | "false" | "no" | "off" => Ok(false),
        "1" | "true" | "yes" | "on" => Ok(true),
        _ => request_error(format!(
            "${name} must be a boolean (0/1, true/false, yes/no, on/off), got \"{value}\""
        )),
    }
}

fn path(name: &str) -> Option<PathBuf> {
    std::env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// The cache signing key. Empty counts as unset, so a precondition check and
/// the consumer cannot disagree on whether signing is on.
pub fn signing_key() -> Result<Option<String>> {
    optional("NIX_SIGNING_KEY")
}

/// The credentials a `--push-cache` run needs, whichever are set: the
/// signing key and the S3 credentials the uploader's `nix copy` reads.
pub fn push_credentials() -> Result<Vec<(String, String)>> {
    let mut pairs = Vec::new();
    for name in [
        "NIX_SIGNING_KEY",
        "AWS_ACCESS_KEY_ID",
        "AWS_SECRET_ACCESS_KEY",
        "AWS_SESSION_TOKEN",
        "AWS_DEFAULT_REGION",
    ] {
        if let Some(value) = optional(name)? {
            pairs.push((name.to_string(), value));
        }
    }
    Ok(pairs)
}

/// The deployed cargo registry's publish token; live publishes demand it,
/// dry runs never read it.
pub fn wasix_cargo_token() -> Result<Option<String>> {
    optional("WASIX_CARGO_TOKEN")
}

/// Whether the mutation push credential is the CI-cascading PAT: the
/// workflow states it explicitly ("true"/"false"), and absence means the
/// adapter did not say.
pub fn update_pr_token_present() -> Result<Option<bool>> {
    Ok(optional("WASINIX_UPDATE_PR_TOKEN_PRESENT")?.map(|value| value == "true"))
}

/// The update driver's request to the package script it invoked, as JSON.
pub fn update_request() -> Result<Option<String>> {
    optional(crate::update::REQUEST_ENV)
}

pub fn github_repository() -> Result<Option<String>> {
    optional("GITHUB_REPOSITORY")
}

pub fn github_event_path() -> Result<Option<String>> {
    optional("GITHUB_EVENT_PATH")
}

/// The workflow run a step belongs to, which its own step records are
/// keyed by.
pub fn github_run_id() -> Result<Option<String>> {
    optional("GITHUB_RUN_ID")
}

pub fn github_sha() -> Result<Option<String>> {
    optional("GITHUB_SHA")
}

pub fn github_workflow() -> Result<Option<String>> {
    optional("GITHUB_WORKFLOW")
}

/// The workflow run's own page, which a reply links to for the detail it
/// cannot carry. Absent off a runner.
pub fn github_run_url() -> Result<Option<String>> {
    let (Some(server), Some(repository), Some(run_id)) = (
        optional("GITHUB_SERVER_URL")?,
        github_repository()?,
        github_run_id()?,
    ) else {
        return Ok(None);
    };
    Ok(Some(format!(
        "{server}/{repository}/actions/runs/{run_id}"
    )))
}

pub fn github_token() -> Option<String> {
    ["GH_TOKEN", "GITHUB_TOKEN"]
        .iter()
        .find_map(|name| optional(name).ok().flatten())
}

/// The wasmer registry python commands talk to. wasmer.io is production,
/// wasmer.fun staging, wasmer.wtf dev; the default is production.
pub fn wasmer_registry() -> Result<String> {
    Ok(optional("WASMER_REGISTRY")?.unwrap_or_else(|| "wasmer.io".to_string()))
}

pub fn wasinix_remote() -> Result<Option<String>> {
    optional("WASINIX_REMOTE")
}

/// An explicit builders.toml location, overriding the config path.
pub fn wasinix_builders() -> Option<PathBuf> {
    path("WASINIX_BUILDERS")
}

/// The pre-rename spelling, detected only to refuse it loudly.
pub fn legacy_remotes_set() -> bool {
    std::env::var_os("WASINIX_REMOTES").is_some()
}

pub fn eval_workers() -> Result<Option<usize>> {
    positive("WASINIX_EVAL_WORKERS")
}

pub fn eval_memory() -> Result<Option<usize>> {
    positive("WASINIX_EVAL_MEMORY")
}

pub fn max_jobs() -> Result<Option<usize>> {
    positive("WASINIX_MAX_JOBS")
}

pub fn eval_timeout() -> Result<Option<Duration>> {
    duration_secs("WASINIX_EVAL_TIMEOUT_SECONDS")
}

pub fn build_timeout() -> Result<Option<Duration>> {
    duration_secs("WASINIX_BUILD_TIMEOUT_SECONDS")
}

pub fn stall_timeout() -> Result<Option<Duration>> {
    duration_secs("WASINIX_STALL_SECONDS")
}

pub fn no_baseline_reuse() -> Result<bool> {
    flag("CI_NO_BASELINE_REUSE")
}

pub fn host_lease_root() -> Result<Option<String>> {
    optional("WASINIX_HOST_LEASE_ROOT")
}

pub fn host_lease_capacity() -> Result<Option<usize>> {
    positive("WASINIX_HOST_LEASE_CAPACITY")
}

pub fn xdg_config_home() -> Option<PathBuf> {
    path("XDG_CONFIG_HOME")
}

pub fn xdg_state_home() -> Option<PathBuf> {
    path("XDG_STATE_HOME")
}

pub fn xdg_runtime_dir() -> Option<PathBuf> {
    path("XDG_RUNTIME_DIR")
}

pub fn home() -> Option<PathBuf> {
    path("HOME")
}

pub fn term_is_dumb() -> bool {
    std::env::var("TERM").ok().as_deref() == Some("dumb")
}

pub fn no_color() -> bool {
    std::env::var_os("NO_COLOR").is_some()
}

pub fn clicolor_force() -> bool {
    std::env::var("CLICOLOR_FORCE")
        .map(|value| !value.is_empty() && value != "0")
        .unwrap_or(false)
}

pub fn temp_dir() -> PathBuf {
    std::env::temp_dir()
}

pub fn current_exe() -> Result<PathBuf> {
    std::env::current_exe().map_err(|e| crate::support::error::io("wasinix", e))
}

/// Whether a spawn of this program word could succeed: a path is checked as
/// given, a bare name must resolve on PATH.
pub fn on_path(program: &str) -> bool {
    if program.contains('/') {
        return std::path::Path::new(program).exists();
    }
    std::env::var_os("PATH")
        .map(|path| std::env::split_paths(&path).any(|dir| dir.join(program).is_file()))
        .unwrap_or(false)
}

/// The subcommand as typed, for messages naming the app that would have
/// carried a missing tool.
pub fn arg1() -> Option<String> {
    std::env::args()
        .nth(1)
        .filter(|argument| !argument.starts_with('-'))
}

/// Test-only: regenerate golden fixtures instead of comparing against them.
#[cfg(test)]
pub fn update_goldens() -> bool {
    std::env::var_os("WASINIX_UPDATE_GOLDENS").is_some()
}

#[cfg(test)]
mod tests {
    // The parse rules are process-global state, so each test owns a variable
    // name no other test touches.

    #[test]
    fn positive_rejects_zero_and_garbage() {
        std::env::set_var("WASINIX_TEST_POSITIVE", "0");
        assert!(super::positive("WASINIX_TEST_POSITIVE").is_err());
        std::env::set_var("WASINIX_TEST_POSITIVE", "12");
        assert_eq!(super::positive("WASINIX_TEST_POSITIVE").unwrap(), Some(12));
        std::env::remove_var("WASINIX_TEST_POSITIVE");
        assert_eq!(super::positive("WASINIX_TEST_POSITIVE").unwrap(), None);
    }

    #[test]
    fn flags_accept_the_usual_spellings_and_reject_garbage() {
        for falsy in ["0", "false", "No", "off", "  0 "] {
            std::env::set_var("WASINIX_TEST_FLAG", falsy);
            assert!(!super::flag("WASINIX_TEST_FLAG").unwrap(), "{falsy}");
        }
        for truthy in ["1", "true", "YES", "on", " On "] {
            std::env::set_var("WASINIX_TEST_FLAG", truthy);
            assert!(super::flag("WASINIX_TEST_FLAG").unwrap(), "{truthy}");
        }
        std::env::set_var("WASINIX_TEST_FLAG", "maybe");
        assert!(super::flag("WASINIX_TEST_FLAG").is_err());
        std::env::remove_var("WASINIX_TEST_FLAG");
        assert!(!super::flag("WASINIX_TEST_FLAG").unwrap());
    }
}
