//! The state a bot-managed pull request carries in its own body: the recipe
//! that generates the branch and the last head the bot wrote. "Pushing
//! pauses refreshes" is decided from this record, never guessed from shas.

use base64::Engine;
use serde::{Deserialize, Serialize};

use crate::support::error::{Result, request_error, require};

const DATA_PREFIX: &str = "<!-- wasinix:changeset data=";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct State {
    pub schema: u32,
    /// The `/wasinix` command that regenerates the branch, re-parsed through
    /// the untrusted grammar on every replay, never shelled.
    pub recipe: String,
    /// The head the bot last wrote; a branch past it is paused.
    pub rewrite_safe_head: String,
    /// This update had no fired notes when the bot created its managed state.
    #[serde(default)]
    pub auto_merge: bool,
}

impl State {
    pub fn new(recipe: String, head: String) -> Result<State> {
        require(!recipe.is_empty(), "managed PR recipe is empty")?;
        require(
            head.is_empty() || crate::support::atoms::Rev::parse(&head).is_ok(),
            "managed PR head is not a commit SHA",
        )?;
        Ok(State {
            schema: 1,
            recipe,
            rewrite_safe_head: head,
            auto_merge: false,
        })
    }
}

/// The state recorded in a PR body, or None for an unmanaged PR. A marker
/// that fails to decode is an error: it means the record was tampered with
/// or corrupted, which must never read as "not managed".
pub fn decode(body: &str) -> Result<Option<State>> {
    let encoded = body.lines().rev().find_map(|line| {
        line.strip_prefix(DATA_PREFIX)
            .and_then(|value| value.strip_suffix(" -->"))
    });
    let Some(encoded) = encoded else {
        return Ok(None);
    };
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| crate::support::error::Error::Request("invalid managed PR state".into()))?;
    let state: State =
        serde_json::from_slice(&bytes).map_err(|source| crate::support::error::Error::Json {
            path: "<managed PR state>".into(),
            source,
        })?;
    require(state.schema == 1, "unsupported managed PR state schema")?;
    let mut validated = State::new(state.recipe, state.rewrite_safe_head)?;
    validated.auto_merge = state.auto_merge;
    Ok(Some(validated))
}

/// The marker line carrying the state; appended to (or replaced in) the PR
/// body, so the PR document is the single home of its own management record.
pub fn marker(state: &State) -> Result<String> {
    let encoded = base64::engine::general_purpose::STANDARD.encode(
        serde_json::to_vec(state).map_err(|source| crate::support::error::Error::Json {
            path: "<managed PR state>".into(),
            source,
        })?,
    );
    Ok(format!("{DATA_PREFIX}{encoded} -->"))
}

/// The PR body with `state` recorded: the existing marker line replaced, or
/// the marker appended.
pub fn with_state(body: &str, state: &State) -> Result<String> {
    let marker = marker(state)?;
    let mut lines: Vec<&str> = body.lines().collect();
    match lines.iter().position(|line| line.starts_with(DATA_PREFIX)) {
        Some(index) => lines[index] = &marker,
        None => {
            lines.push("");
            lines.push(&marker);
        }
    }
    let mut rendered = lines.join("\n");
    rendered.push('\n');
    Ok(rendered)
}

/// Whether automated refreshes are paused: the bot recorded a head and the
/// branch has moved past it, so a refresh would replace someone's commits.
pub fn paused(state: &State, head_sha: &str) -> bool {
    !state.rewrite_safe_head.is_empty() && !state.rewrite_safe_head.eq_ignore_ascii_case(head_sha)
}

/// A bare `update` or a `regenerate` replays the recorded recipe; refuse
/// both anywhere the record does not exist.
pub fn require_state(state: Option<State>, what: &str) -> Result<State> {
    state.ok_or_else(|| {
        crate::support::error::Error::Request(format!(
            "{what} requires a wasinix-managed pull request"
        ))
    })
}

pub fn parse_recipe(recipe: &str) -> Result<crate::cli::CommandTree> {
    let command = crate::cli::untrusted::parse(recipe)?;
    if crate::cli::untrusted::mutation_recipe(&command).is_some() {
        Ok(command)
    } else {
        request_error("the recorded recipe is not a replayable mutation command")
    }
}
