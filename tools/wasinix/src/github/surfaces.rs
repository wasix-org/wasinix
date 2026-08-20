//! The registry of GitHub surfaces the tool writes. Every published page is
//! one marked comment; upsert, marker lookup, and id caching live here once,
//! and the sticky set is closed, so the bot can never flood a PR.

use std::collections::HashMap;

use serde_json::{Value, json};

/// GitHub caps issue comments at 65536 bytes; this leaves generous headroom
/// while keeping reports scannable, with the step summary as overflow.
pub const COMMENT_BUDGET: usize = 30_000;

/// The one login the bot's surfaces carry; upsert matching and the clap
/// defaults all read it here.
pub const BOT_AUTHOR: &str = "github-actions[bot]";
/// The commit identity paired with [`BOT_AUTHOR`].
pub const BOT_EMAIL: &str = "41898282+github-actions[bot]@users.noreply.github.com";

use crate::github::client::Client;
use crate::support::error::{Error, Result};

/// The GitHub coordinates every publishing arm shares, resolved one way.
#[derive(clap::Args)]
pub struct SurfaceArgs {
    /// OWNER/REPO; $GITHUB_REPOSITORY, then the checkout's origin, when absent
    #[arg(long)]
    pub repository: Option<String>,
    #[arg(long)]
    pub pull_request: Option<u64>,
    /// The bot login the comments carry
    #[arg(long, default_value = BOT_AUTHOR)]
    pub author: String,
    /// The workflow run URL the surfaces link
    #[arg(long)]
    pub run_url: Option<String>,
}

impl SurfaceArgs {
    pub fn repository(&self, repo: &std::path::Path) -> Result<String> {
        resolve_repository(self.repository.as_deref(), repo)
    }
}

static GITHUB_REMOTE: std::sync::LazyLock<regex::Regex> = std::sync::LazyLock::new(|| {
    regex::Regex::new(r"github\.com[:/]([^/]+)/([^/.]+?)(?:\.git)?$").unwrap()
});

/// Flag, then $GITHUB_REPOSITORY, then the checkout's GitHub origin;
/// lowercased once, since GitHub compares OWNER/REPO case-insensitively and
/// every equality check in the tool runs on this value.
pub fn resolve_repository(flag: Option<&str>, repo: &std::path::Path) -> Result<String> {
    if let Some(repository) = flag {
        // Taken verbatim, a url went straight into an api path and came back
        // as a 404 naming the path rather than the mistake.
        return named_repository(repository).ok_or_else(|| {
            Error::Request(format!(
                "--repository {repository:?}: expected OWNER/REPO, or a github.com url for it"
            ))
        });
    }
    detected_repository(repo)
        .or_else(|| github_remote(repo))
        .ok_or_else(|| {
            Error::Request(
                "no repository: pass --repository, set GITHUB_REPOSITORY, \
                 or add a github.com remote"
                    .into(),
            )
        })
}

/// `OWNER/REPO`, however it was spelled: a bare pair, or any of the urls a
/// github remote is written as.
fn named_repository(value: &str) -> Option<String> {
    if let Some(captures) = GITHUB_REMOTE.captures(value) {
        return Some(format!("{}/{}", &captures[1], &captures[2]).to_lowercase());
    }
    let (owner, name) = value.split_once('/')?;
    let named = !owner.is_empty() && !name.is_empty() && !name.contains('/');
    named.then(|| value.to_lowercase())
}

/// Any remote naming a github repository, for a checkout whose remote is not
/// called origin. Read-only callers only: the identity a mutation checks
/// against stays the origin's.
fn github_remote(repo: &std::path::Path) -> Option<String> {
    let remotes = crate::support::git::git(repo, &["remote"]).ok()?;
    remotes.lines().find_map(|name| {
        let url = crate::support::git::git(repo, &["remote", "get-url", name]).ok()?;
        GITHUB_REMOTE
            .captures(&url)
            .map(|captures| format!("{}/{}", &captures[1], &captures[2]).to_lowercase())
    })
}

/// The repository the environment implies: $GITHUB_REPOSITORY, else the
/// checkout's GitHub origin remote.
pub fn detected_repository(repo: &std::path::Path) -> Option<String> {
    if let Ok(Some(value)) = crate::support::env::github_repository() {
        return Some(value.to_lowercase());
    }
    origin_repository(repo)
}

/// The checkout's own GitHub repository, from its origin remote alone.
pub fn origin_repository(repo: &std::path::Path) -> Option<String> {
    let remote = crate::support::git::git(repo, &["remote", "get-url", "origin"]).ok()?;
    GITHUB_REMOTE
        .captures(&remote)
        .map(|captures| format!("{}/{}", &captures[1], &captures[2]).to_lowercase())
}

/// Every surface the bot may write. Only [`Surface::sticky`] surfaces exist
/// once per PR; the keyed ones are bounded by the comments users post.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Surface {
    /// The CI report, edited in place through running, final, and invalid.
    CiReport,
    /// A reply to one `/wasinix` command comment.
    CiReportReply { comment_id: u64 },
    /// A reply to one `/wasinix` mutation comment.
    Mutation { comment_id: u64 },
    /// The registry preview for a PR.
    Preview,
}

/// The web address of the comment a reply answers, so a reader arriving at
/// the reply can find what asked for it.
pub fn origin_comment_url(repository: &str, pull_request: u64, comment_id: u64) -> String {
    format!("https://github.com/{repository}/pull/{pull_request}#issuecomment-{comment_id}")
}

impl Surface {
    fn name(&self) -> String {
        match self {
            Surface::CiReport => "ci-report".to_string(),
            Surface::CiReportReply { comment_id } => format!("ci-report:{comment_id}"),
            Surface::Mutation { comment_id } => format!("mutation:{comment_id}"),
            Surface::Preview => "preview".to_string(),
        }
    }

    /// The prefix a lookup matches: attributes after it may change between
    /// edits, the identity may not. The trailing space terminates the name,
    /// so `ci-report` does not match a `ci-report:<id>` reply (whose name is
    /// followed by a colon), which would let a reply be adopted as the sticky
    /// report.
    fn marker_prefix(&self) -> String {
        format!("<!-- wasinix:{} ", self.name())
    }

    /// The marker written on the first line, carrying provenance attributes.
    /// It opens with the match prefix, so a written marker always matches its
    /// own lookup.
    pub fn marker(&self, attributes: &[(&str, String)]) -> String {
        let mut marker = self.marker_prefix();
        for (key, value) in attributes {
            marker += &format!("{key}={value} ");
        }
        marker += "-->";
        marker
    }

    /// Markers from before the surface scheme, matched once so live PRs
    /// migrate on their next upsert instead of growing a second comment.
    fn legacy_prefixes(&self) -> &'static [&'static str] {
        match self {
            Surface::CiReport => &["<!-- wasinix-ci-report -->"],
            Surface::Preview => &["<!-- wasinix-preview -->"],
            _ => &[],
        }
    }
}

/// The GitHub operations upsert needs, so tests can run against a fake.
pub trait CommentApi {
    fn paginate(&self, path: &str) -> Result<Vec<Value>>;
    fn post(&self, path: &str, body: &Value) -> Result<Value>;
    fn patch(&self, path: &str, body: &Value) -> Result<Value>;
}

impl CommentApi for Client {
    fn paginate(&self, path: &str) -> Result<Vec<Value>> {
        Client::paginate(self, path)
    }

    fn post(&self, path: &str, body: &Value) -> Result<Value> {
        Client::post(self, path, body)
    }

    fn patch(&self, path: &str, body: &Value) -> Result<Value> {
        Client::patch(self, path, body)
    }
}

pub struct Registry<'a> {
    pub api: &'a dyn CommentApi,
    pub repository: String,
    pub pull_request: u64,
    /// The bot login upserts must match; a marker in someone else's comment
    /// is content, never state.
    pub author: String,
    effects: crate::support::effects::Effects,
    cache: HashMap<Surface, u64>,
}

impl<'a> Registry<'a> {
    pub fn new(
        api: &'a dyn CommentApi,
        repository: impl Into<String>,
        pull_request: u64,
        author: impl Into<String>,
        effects: crate::support::effects::Effects,
    ) -> Registry<'a> {
        Registry {
            api,
            repository: repository.into(),
            pull_request,
            author: author.into(),
            effects,
            cache: HashMap::new(),
        }
    }
}

impl Registry<'_> {
    fn comments_path(&self) -> String {
        format!(
            "repos/{}/issues/{}/comments",
            self.repository, self.pull_request
        )
    }

    fn matches(&self, surface: &Surface, comment: &Value) -> bool {
        let author = comment["user"]["login"].as_str().unwrap_or_default();
        if author != self.author {
            return false;
        }
        let first_line = comment["body"]
            .as_str()
            .unwrap_or_default()
            .lines()
            .next()
            .unwrap_or_default();
        first_line.starts_with(&surface.marker_prefix())
            || surface
                .legacy_prefixes()
                .iter()
                .any(|legacy| first_line.starts_with(legacy))
    }

    /// The surface's comment id, from the cache or a first-match page walk.
    pub fn find(&mut self, surface: &Surface) -> Result<Option<u64>> {
        if let Some(id) = self.cache.get(surface) {
            return Ok(Some(*id));
        }
        let comments = self.api.paginate(&self.comments_path())?;
        for comment in &comments {
            if self.matches(surface, comment) {
                if let Some(id) = comment["id"].as_u64() {
                    self.cache.insert(surface.clone(), id);
                    return Ok(Some(id));
                }
            }
        }
        Ok(None)
    }

    /// Write the surface: the marker line, then the rendered body, truncated
    /// as one assembly so marker plus body never exceed the budget. One
    /// comment per surface, edited in place across states; a body can only
    /// arrive as [`Markdown`], so unsanitized text cannot reach a comment.
    /// A dry run renders and budgets the full assembly, then stops short of
    /// the write and returns no id.
    pub fn upsert(
        &mut self,
        surface: &Surface,
        attributes: &[(&str, String)],
        body: crate::github::sanitize::Markdown,
    ) -> Result<Option<u64>> {
        let text = crate::github::markdown::truncate_sections(
            format!("{}\n{}", surface.marker(attributes), body.into_string()),
            COMMENT_BUDGET,
        );
        if self.effects.is_dry_run() {
            crate::support::ui::fact(
                "comment",
                format!("skipped (dry run), {} bytes", text.len()),
            );
            return Ok(None);
        }
        let payload = json!({ "body": text });
        if let Some(id) = self.find(surface)? {
            self.api.patch(
                &format!("repos/{}/issues/comments/{id}", self.repository),
                &payload,
            )?;
            return Ok(Some(id));
        }
        let created = self.api.post(&self.comments_path(), &payload)?;
        let id = created["id"]
            .as_u64()
            .ok_or_else(|| Error::Failure("created comment has no id".into()))?;
        self.cache.insert(surface.clone(), id);
        Ok(Some(id))
    }
}
