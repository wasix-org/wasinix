//! The PR preview: diff the checkout against a base, push changed webcs as
//! prerelease versions, deploy changed wheels as an ephemeral index app, and
//! keep the PR's one preview comment current through building, published,
//! and failed.

use std::path::{Path, PathBuf};

use crate::github::sanitize::Markdown;
use crate::github::surfaces::{Registry, Surface};
use crate::registries::{cargo, python, wasmer};
use crate::support::error::{Error, Result};
use crate::support::process::CommandStatus;
use crate::github::client;
use crate::support::ui;

#[derive(Clone, Copy, PartialEq, clap::ValueEnum)]
pub enum Status {
    /// The claim posted before the long work, so the PR shows it is coming
    Building,
    /// Posted by the adapter when the job died outside this command
    Failed,
}

#[derive(clap::Args)]
pub struct PreviewArgs {
    /// The prerelease tag, e.g. pr123.gabc1234
    #[arg(value_name = "TAG")]
    pub tag: String,
    /// The base checkout the preview diffs against
    #[arg(long)]
    pub base: Option<PathBuf>,
    /// Post only this status to the preview comment, then exit
    #[arg(long, value_enum)]
    pub status: Option<Status>,
    /// Registry the webc prereleases go to
    #[arg(long, default_value = "wasmer.io")]
    pub registry: String,
    /// Namespace the prereleases and the ephemeral apps land in, never one
    /// carrying released packages
    #[arg(long)]
    pub namespace: Option<String>,
    /// Rev recorded in each published webc README
    #[arg(long)]
    pub rev: Option<String>,
    #[arg(long)]
    pub dry_run: bool,
    /// Upsert the PR's preview comment with the outcome
    #[arg(long, requires = "pull_request")]
    pub comment: bool,
    #[command(flatten)]
    pub surface: crate::github::surfaces::SurfaceArgs,
}

struct Comment {
    client: client::Client,
    repository: String,
    pull_request: u64,
    author: String,
    effects: crate::support::effects::Effects,
}

impl Comment {
    fn open(args: &PreviewArgs, repo: &Path) -> Result<Option<Comment>> {
        let Some(pull_request) = args.surface.pull_request else {
            return Ok(None);
        };
        Ok(Some(Comment {
            client: client::Client::new(None),
            repository: args.surface.repository(repo)?,
            pull_request,
            author: args.surface.author.clone(),
            effects: crate::support::effects::Effects::from_dry_run(args.dry_run),
        }))
    }

    fn upsert(&self, body: Markdown, sha: Option<&str>) -> Result<()> {
        let mut registry = Registry::new(
            &self.client,
            self.repository.clone(),
            self.pull_request,
            &self.author,
            self.effects,
        );
        let mut attributes = Vec::new();
        if let Some(sha) = sha {
            attributes.push(("sha", sha.to_string()));
        }
        registry.upsert(&Surface::Preview, &attributes, body)?;
        Ok(())
    }
}

fn run_link(args: &PreviewArgs) -> Markdown {
    match args.surface.run_url.as_deref() {
        Some(url) => Markdown::concat([
            Markdown::constant(" ("),
            Markdown::link("run", url),
            Markdown::constant(")"),
        ]),
        None => Markdown::new(),
    }
}

fn status_body(args: &PreviewArgs, status: Status) -> Markdown {
    let rev = args.rev.as_deref().unwrap_or("HEAD");
    let short: String = rev.chars().take(7).collect();
    let line = match status {
        Status::Building => Markdown::concat([
            Markdown::constant("Building for "),
            Markdown::code(&short),
            Markdown::constant("..."),
        ]),
        Status::Failed => Markdown::concat([
            Markdown::constant("Failed for "),
            Markdown::code(&short),
            Markdown::constant("."),
        ]),
    };
    Markdown::concat([
        Markdown::constant("### PR preview\n\n"),
        line,
        run_link(args),
        Markdown::constant("\n"),
    ])
}

/// The production index url the pip line pairs the overlay with; the preview
/// still renders without it, so a lookup failure only costs the hint.
fn prod_index_url() -> Option<String> {
    let mut get = std::process::Command::new("wasmer");
    get.args(["app", "get", "wasmer/python-registry"])
        .args(["--registry", "wasmer.io"])
        .args(["--format", "json"]);
    let output = crate::support::tools::output(&mut get).ok()?;
    if !output.status.success() {
        return None;
    }
    let app: serde_json::Value = serde_json::from_slice(&output.stdout).ok()?;
    app["url"].as_str().map(str::to_string)
}

fn published_body(
    args: &PreviewArgs,
    plan: &python::PlanDiff,
    index_url: Option<&str>,
    cargo_preview: Option<&(String, Vec<String>)>,
) -> Markdown {
    let mut body = Markdown::concat([
        Markdown::constant("### PR preview ("),
        Markdown::code(&args.tag),
        Markdown::constant(")\n"),
    ]);
    if !plan.webcs.is_empty() {
        body = Markdown::concat([
            body,
            Markdown::constant("\nWebcs on "),
            Markdown::code(&args.registry),
            Markdown::constant(" (failures listed in the workflow log):\n"),
        ]);
        for webc in &plan.webcs {
            // The plan's owner is the manifest's; the preview publishes under
            // the namespace, so the run line has to name that one.
            let owner = args.namespace.as_deref().unwrap_or(&webc.owner);
            body = Markdown::concat([
                body,
                Markdown::constant("- "),
                Markdown::code(&format!(
                    "wasmer run {owner}/{}@{}-{} --registry {}",
                    webc.name, webc.version, args.tag, args.registry
                )),
                Markdown::constant("\n"),
            ]);
        }
    }
    if let Some(url) = index_url {
        let prod = prod_index_url();
        // The pip line is a fence, so both urls are payload, not markup.
        body = Markdown::concat([
            body,
            Markdown::constant("\nWheel overlay "),
            Markdown::link("index", url),
            Markdown::constant(
                ", preferred over the published wheels by version:\n",
            ),
            Markdown::fenced(
                &format!(
                    "pip install --index-url {url}/all/simple --extra-index-url {}/all/simple <pkg>",
                    prod.as_deref().unwrap_or("<prod index>")
                ),
                "",
            ),
        ]);
    }
    if let Some((url, specs)) = cargo_preview {
        body = Markdown::concat([
            body,
            Markdown::constant("\nCargo overlay "),
            Markdown::link("index", url),
            Markdown::constant(", serving "),
            Markdown::text(&specs.len().to_string()),
            Markdown::constant(" changed crates as a separate registry:\n"),
            // A static index cannot pass through to crates.io, so it is
            // named as its own registry; the fence keeps the url as payload.
            Markdown::fenced(
                &format!(
                    "[registries.wasix-preview]\nindex = \"sparse+{url}/\"\n# cargo add <crate> --registry wasix-preview"
                ),
                "toml",
            ),
        ]);
        for spec in specs {
            body = Markdown::concat([
                body,
                Markdown::constant("- "),
                Markdown::code(spec),
                Markdown::constant("\n"),
            ]);
        }
    }
    body = body.push(Markdown::constant("\n"));
    if let Some(url) = args.surface.run_url.as_deref() {
        body = body.push(Markdown::link("workflow run", url));
    }
    body.push(Markdown::constant("\n"))
}

fn publish(args: &PreviewArgs, repo: &Path) -> Result<()> {
    let base = args.base.as_ref().ok_or_else(|| {
        Error::Request("a preview needs --base to diff against".into())
    })?;
    // Checked before the diff, which builds both plans: the namespace is
    // wanted by every step below, and wasmer::publish refuses without it.
    let namespace = args.namespace.clone().ok_or_else(|| {
        Error::Request("a preview needs --namespace to publish into".into())
    })?;
    let plan = python::plan_diff(&base.to_string_lossy())?;
    ui::fact("changed webcs", plan.webcs.len());
    ui::fact("changed wheels", plan.wheels.len());

    if !plan.webcs.is_empty() {
        wasmer::publish(wasmer::Options {
            registry: args.registry.clone(),
            packages: plan.webcs.iter().map(|webc| webc.attr.clone()).collect(),
            effects: crate::support::effects::Effects::from_dry_run(args.dry_run),
            skip_sha_validation: false,
            rev: args.rev.clone(),
            preview: Some(args.tag.clone()),
            with_dependencies: false,
            publish_as: None,
            namespace: Some(namespace.clone()),
        })?;
    }

    let mut index_url = None;
    if !plan.wheels.is_empty() {
        let scratch = crate::support::fs::Scratch::create("wasinix-preview-index")?;
        let site = scratch.path().join("site");
        python::preview_index(repo, &plan.wheels, &args.tag, scratch.path(), &site)?;
        let pull_request = args.surface.pull_request.ok_or_else(|| {
            Error::Request("deploying a wheel preview needs --pull-request for the app name".into())
        })?;
        if args.dry_run {
            ui::fact("index", "built; deploy skipped (dry run)");
        } else {
            let url = python::preview(python::Preview {
                site,
                app: format!("python-registry-pr{pull_request}"),
                owner: namespace.clone(),
                registry: args.registry.clone(),
            })?;
            ui::fact("index", &url);
            index_url = Some(url);
        }
    }

    // The cargo overlay: changed minted crates as a static sparse index on
    // the same ephemeral-app lifecycle as the wheel preview.
    let base_mint = cargo::mint_from(&format!("path:{}", base.display()))?;
    let cargo_preview = cargo::preview(cargo::PreviewOptions {
        app: args
            .surface
            .pull_request
            .map(|pull_request| format!("cargo-registry-pr{pull_request}")),
        owner: namespace.clone(),
        registry: args.registry.clone(),
        mint: None,
        base_mint: Some(base_mint),
        effects: crate::support::effects::Effects::from_dry_run(args.dry_run),
    })?;
    if let Some((url, specs)) = &cargo_preview {
        ui::fact("cargo index", url);
        ui::fact("cargo crates", specs.len());
    }

    if args.comment {
        if let Some(comment) = Comment::open(args, repo)? {
            comment.upsert(
                published_body(args, &plan, index_url.as_deref(), cargo_preview.as_ref()),
                args.rev.as_deref(),
            )?;
        }
    }
    Ok(())
}

pub fn run(args: PreviewArgs) -> Result<CommandStatus> {
    let repo = crate::support::git::repo_root()?;
    if let Some(status) = args.status {
        if let Some(comment) = Comment::open(&args, &repo)? {
            comment.upsert(status_body(&args, status), args.rev.as_deref())?;
        }
        return Ok(CommandStatus::SUCCESS);
    }
    match publish(&args, &repo) {
        Ok(()) => Ok(CommandStatus::SUCCESS),
        Err(error) => {
            // The failure comment goes out before the error, so the PR never
            // shows a stale "building" claim for a run that already died.
            if args.comment {
                if let Ok(Some(comment)) = Comment::open(&args, &repo) {
                    let _ =
                        comment.upsert(status_body(&args, Status::Failed), args.rev.as_deref());
                }
            }
            Err(error)
        }
    }
}
