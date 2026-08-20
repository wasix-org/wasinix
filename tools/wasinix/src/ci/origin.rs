//! Where a cross-repository command came from, and whether it really did: an
//! origin grants a reporting destination in another repository, so shape
//! validation is not enough. The fields that grant anything are read back from
//! the API.

use std::sync::LazyLock;

use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::github::client;
use crate::support::atoms::Rev;
use crate::support::error::{request_error, require, Error, Result};
use crate::support::schema::{self, Document};

pub const PREFIX: &str = "/wasinix";

pub static REPOSITORY: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,38}/[A-Za-z0-9][A-Za-z0-9._-]{0,99}$").unwrap()
});
pub static LOGIN: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[A-Za-z0-9][A-Za-z0-9-]{0,38}$").unwrap());

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Origin {
    pub repository: String,
    pub pull_request: u64,
    pub head_sha: String,
    pub comment_id: u64,
    pub actor: String,
}

impl Document for Origin {
    const KIND: &'static str = "origin";
    const SCHEMA: u32 = 1;
}

pub fn validate(value: &Value, allowed_owner: Option<&str>) -> Result<Origin> {
    let origin: Origin = schema::from_value(value.clone(), "CI command origin")
        .map_err(|error| Error::Request(format!("invalid CI command origin: {error}")))?;
    require(
        REPOSITORY.is_match(&origin.repository),
        "invalid CI command origin: repository must be OWNER/REPO",
    )?;
    if let Some(owner) = allowed_owner {
        let actual = origin.repository.split('/').next().unwrap_or_default();
        require(
            actual.eq_ignore_ascii_case(owner),
            "invalid CI command origin: repository owner is not allowed",
        )?;
    }
    require(
        origin.pull_request > 0,
        "invalid CI command origin: pullRequest must be a positive integer",
    )?;
    require(
        origin.comment_id > 0,
        "invalid CI command origin: commentId must be a positive integer",
    )?;
    require(
        Rev::parse(&origin.head_sha).is_ok() && origin.head_sha == origin.head_sha.to_lowercase(),
        "invalid CI command origin: headSha must be a lowercase commit SHA",
    )?;
    require(
        LOGIN.is_match(&origin.actor),
        "invalid CI command origin: actor must be a GitHub login",
    )?;
    Ok(origin)
}

/// A GitHub reader, so verification can be tested without the network.
pub trait Api {
    fn get(&self, path: &str) -> Result<Value>;
}

pub struct Rest {
    pub token: Option<String>,
}

impl Api for Rest {
    fn get(&self, path: &str) -> Result<Value> {
        client::Client::new(self.token.as_deref()).get(path)
    }
}

/// What a command is, decided by the one grammar. The CLI layer provides the
/// implementation by re-entering its own parser; verification only needs the
/// classification, never the parse.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandKind {
    Build,
    /// The command rewrites the pull request's branch.
    Mutation,
    /// The command only replies; no run, no report, no build machinery.
    Help,
}

impl CommandKind {
    pub fn as_str(self) -> &'static str {
        match self {
            CommandKind::Build => "build",
            CommandKind::Mutation => "mutation",
            CommandKind::Help => "help",
        }
    }
}

pub trait Classifier {
    fn classify(&self, command: &str) -> Result<CommandKind>;
}

fn require_write_permission(repository: &str, actor: &str, api: &dyn Api) -> Result<()> {
    let permission = api.get(&format!(
        "repos/{repository}/collaborators/{actor}/permission"
    ))?;
    // role_name distinguishes maintain from write, which the legacy field
    // collapses together.
    let role = permission["role_name"]
        .as_str()
        .or_else(|| permission["permission"].as_str())
        .unwrap_or_default();
    require(
        ALLOWED_PERMISSIONS.contains(&role),
        "invalid CI comment: commenter needs write permission",
    )
}

/// Re-derive an origin from the comment it claims to come from.
pub fn verify(
    origin: &Origin,
    command: &str,
    api: &dyn Api,
    classifier: &dyn Classifier,
) -> Result<()> {
    let comment = api.get(&format!(
        "repos/{}/issues/comments/{}",
        origin.repository, origin.comment_id
    ))?;
    let author = comment["user"]["login"].as_str().unwrap_or_default();
    require(
        author.eq_ignore_ascii_case(&origin.actor),
        format!(
            "comment {} was written by {}",
            origin.comment_id,
            if author.is_empty() { "nobody" } else { author }
        ),
    )?;
    let issue_url = comment["issue_url"].as_str().unwrap_or_default();
    require(
        issue_url.ends_with(&format!("/issues/{}", origin.pull_request)),
        "comment does not belong to the claimed pull request",
    )?;
    let (actual_command, _) =
        command_from_body(comment["body"].as_str().unwrap_or_default(), classifier)?;
    require(
        actual_command == command,
        "dispatched command does not match the comment",
    )?;
    require_write_permission(&origin.repository, &origin.actor, api)?;
    let pull = api.get(&format!(
        "repos/{}/pulls/{}",
        origin.repository, origin.pull_request
    ))?;
    let head = pull["head"]["sha"]
        .as_str()
        .unwrap_or_default()
        .to_lowercase();
    require(
        head == origin.head_sha,
        "pull request head does not match the origin",
    )?;
    Ok(())
}

/// Authorize a pull-request comment and describe the run it should start.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Command {
    pub command: String,
    /// build or mutation; renamed on the wire because the document envelope
    /// reserves the top-level "kind" key for the document type.
    #[serde(rename = "commandKind")]
    pub kind: String,
    pub origin: Origin,
}

impl Document for Command {
    const KIND: &'static str = "ciCommand";
    const SCHEMA: u32 = 1;
}

const MAX_COMMAND: usize = 4096;
const ALLOWED_PERMISSIONS: [&str; 3] = ["admin", "write", "maintain"];

/// The `/wasinix` directive in a comment body, found on any line, CRLF and
/// case tolerant, with prose around it allowed. Two directives in one comment
/// are ambiguous and refused.
pub fn extract_command(body: &str) -> Result<String> {
    let mut found: Option<String> = None;
    for raw in body.lines() {
        let line = raw.trim();
        if line.len() < PREFIX.len() || !line[..PREFIX.len()].eq_ignore_ascii_case(PREFIX) {
            continue;
        }
        let rest = &line[PREFIX.len()..];
        if !rest.is_empty() && !rest.starts_with(char::is_whitespace) {
            continue;
        }
        if found.is_some() {
            return request_error(
                "invalid CI comment: more than one /wasinix directive in one comment",
            );
        }
        found = Some(rest.trim().to_string());
    }
    let command = match found {
        Some(command) => command,
        None => return request_error(format!("invalid CI comment: no {PREFIX} directive found")),
    };
    require(
        !command.is_empty(),
        format!("invalid CI comment: {PREFIX} names no command; try `{PREFIX} help`"),
    )?;
    require(
        command.len() <= MAX_COMMAND,
        "invalid CI comment: command is too long",
    )?;
    Ok(command)
}

pub fn command_from_body(body: &str, classifier: &dyn Classifier) -> Result<(String, CommandKind)> {
    let command = extract_command(body)?;
    let kind = classifier.classify(&command)?;
    Ok((command, kind))
}

pub fn authorize(
    event: &Value,
    api: &dyn Api,
    classifier: &dyn Classifier,
    allowed_owner: Option<&str>,
) -> Result<Command> {
    require(
        event["action"].as_str() == Some("created"),
        "invalid CI comment: event must create a comment",
    )?;
    require(
        !event["issue"]["pull_request"].is_null(),
        "invalid CI comment: comment is not on a pull request",
    )?;
    let repository = event["repository"]["full_name"]
        .as_str()
        .unwrap_or_default();
    require(
        REPOSITORY.is_match(repository),
        "invalid CI comment: repository must be OWNER/REPO",
    )?;
    let actor = event["comment"]["user"]["login"]
        .as_str()
        .unwrap_or_default();
    require(
        LOGIN.is_match(actor),
        "invalid CI comment: comment author must be a GitHub login",
    )?;
    let pull_request = event["issue"]["number"].as_u64().unwrap_or_default();
    require(
        pull_request > 0,
        "invalid CI comment: pull request number is invalid",
    )?;
    let comment_id = event["comment"]["id"].as_u64().unwrap_or_default();
    require(comment_id > 0, "invalid CI comment: comment id is invalid")?;
    let (command, kind) = command_from_body(
        event["comment"]["body"].as_str().unwrap_or_default(),
        classifier,
    )?;

    require_write_permission(repository, actor, api)?;

    let pull = api.get(&format!("repos/{repository}/pulls/{pull_request}"))?;
    require(
        pull["state"].as_str() == Some("open"),
        "invalid CI comment: pull request is not open",
    )?;
    let base = pull["base"]["repo"]["full_name"]
        .as_str()
        .unwrap_or_default();
    require(
        base.eq_ignore_ascii_case(repository),
        "invalid CI comment: pull request base repository does not match the event",
    )?;

    let origin = validate(
        &schema::to_value(&Origin {
            repository: repository.to_string(),
            pull_request,
            comment_id,
            actor: actor.to_string(),
            head_sha: pull["head"]["sha"]
                .as_str()
                .unwrap_or_default()
                .to_lowercase(),
        })?,
        allowed_owner,
    )?;

    Ok(Command {
        command,
        kind: kind.as_str().to_string(),
        origin,
    })
}
