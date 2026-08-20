//! The overlay cargo registry: stand the deployable up locally, seeded from
//! this repo's fresh mint, so a project can resolve against your own forks.
//! The instance has network, so unforked crates pass through to crates.io.

use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::time::Duration;

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::support::error::{request_error, Result};
use crate::support::process::CommandStatus;
use crate::support::ui;

/// Reads never need it; publish and shadow-limit do.
const TOKEN: &str = "wasix_local";

/// The deployed overlay registry the publish and preview cells default to.
pub const DEPLOYED_REGISTRY: &str = "https://cargo-registry.wasix.org";

fn nix_build(installable: &str) -> Result<PathBuf> {
    let paths = crate::support::nix::Invocation::flake("build", installable)
        .args(["-L", "--no-link"])
        .out_paths(&format!("building {installable}"))?;
    Ok(paths.into_iter().next().expect("out_paths is non-empty"))
}

/// The built mint, or a fresh one when the caller named none; the cargo
/// mirror of python's registry_path.
pub fn mint_path(given: Option<PathBuf>) -> Result<PathBuf> {
    match given {
        Some(path) => Ok(path),
        None => nix_build(".#cargoRegistry"),
    }
}

/// The mint of another checkout (a PR's base), for diffing previews.
pub fn mint_from(flake: &str) -> Result<PathBuf> {
    nix_build(&format!("{flake}#cargoRegistry"))
}

/// One minted build, as manifest.json records it.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct MintCrate {
    #[serde(rename = "crate")]
    name: String,
    wasix_version: String,
    crate_file: String,
    upstream: String,
}

/// The sparse-index file for a crate, per cargo's registry layout.
pub fn index_path(name: &str) -> String {
    let name = name.to_lowercase();
    match name.len() {
        0 => name,
        1 => format!("1/{name}"),
        2 => format!("2/{name}"),
        3 => format!("3/{}/{name}", &name[..1]),
        _ => format!("{}/{}/{name}", &name[..2], &name[2..4]),
    }
}

/// The cksum the index serves for one version, from the newline-delimited
/// entry lines. A malformed line is an error, never "not published".
pub fn index_cksum(index_text: &str, version: &str) -> Result<Option<String>> {
    for line in index_text.lines().filter(|line| !line.trim().is_empty()) {
        let entry: Value =
            serde_json::from_str(line).map_err(|source| crate::support::error::Error::Json {
                path: "<index line>".into(),
                source,
            })?;
        if entry["vers"].as_str() == Some(version) {
            return Ok(entry["cksum"].as_str().map(str::to_string));
        }
    }
    Ok(None)
}

/// The three-way publish decision: absent publishes, byte-identical skips,
/// and a differing checksum is a conflict that only a rel bump resolves.
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Action {
    Publish,
    Skip,
    Conflict,
}

pub fn classify(remote_cksum: Option<&str>, local_cksum: &str) -> Action {
    match remote_cksum {
        None => Action::Publish,
        Some(remote) if remote == local_cksum => Action::Skip,
        Some(_) => Action::Conflict,
    }
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CrateOutcome {
    #[serde(rename = "crate")]
    pub name: String,
    pub version: String,
    pub action: Action,
    pub detail: String,
    /// Whether the wire publish actually happened this run.
    pub published: bool,
}

#[derive(Debug, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PublishReport {
    pub registry: String,
    pub outcomes: Vec<CrateOutcome>,
}

impl crate::support::schema::Document for PublishReport {
    const KIND: &'static str = "cargoPublishPlan";
    const SCHEMA: u32 = 1;
}

/// Which minted builds a spec list selects: every one when empty, else
/// through the address grammar, optionally pinned to one served version.
fn select(entries: &[MintCrate], specs: &[String]) -> Result<Vec<MintCrate>> {
    if specs.is_empty() {
        return Ok(entries.to_vec());
    }
    let mut domain = crate::support::naming::Domain::new("the mint manifest");
    let mut names: Vec<&str> = entries.iter().map(|entry| entry.name.as_str()).collect();
    names.sort_unstable();
    names.dedup();
    for name in names {
        domain.add_path(
            vec!["cargoRegistry".into(), "crates".into(), name.into()],
            name,
            None,
            Vec::new(),
        );
    }
    let mut selected = Vec::new();
    for resolved in crate::support::naming::resolve_all(&domain, specs)? {
        let matches: Vec<&MintCrate> = entries
            .iter()
            .filter(|entry| entry.name == resolved.key)
            .filter(|entry| match &resolved.value {
                None => true,
                Some(version) => &entry.wasix_version == version || &entry.upstream == version,
            })
            .collect();
        if matches.is_empty() {
            return request_error(format!(
                "{}@{}: the mint serves no such version",
                resolved.key,
                resolved.value.as_deref().unwrap_or("?")
            ));
        }
        selected.extend(matches.into_iter().cloned());
    }
    Ok(selected)
}

fn sha256_hex(path: &std::path::Path) -> Result<String> {
    let bytes = std::fs::read(path).map_err(|error| crate::support::error::io(path, error))?;
    Ok(format!("{:x}", Sha256::digest(&bytes)))
}

pub struct PublishOptions {
    /// The deployed registry's base URL.
    pub registry: String,
    pub mint: Option<PathBuf>,
    /// Crate specs, optionally @<version>; empty publishes the whole mint.
    pub crates: Vec<String>,
    pub effects: crate::support::effects::Effects,
}

/// Publish the mint's crates the deployed registry lacks. Idempotent by
/// checksum; a version the index serves with different bytes fails loudly,
/// naming the rel bump that mints a fresh publishable version.
pub fn publish(options: PublishOptions) -> Result<(PublishReport, CommandStatus)> {
    let mint = mint_path(options.mint)?;
    let manifest: Value = crate::support::json::read(&mint.join("manifest.json"))?;
    let entries: Vec<MintCrate> =
        serde_json::from_value(manifest["crates"].clone()).map_err(|source| {
            crate::support::error::Error::Json {
                path: mint.join("manifest.json").display().to_string().into(),
                source,
            }
        })?;
    let selected = select(&entries, &options.crates)?;
    if selected.is_empty() {
        return request_error("the mint holds no crates; nothing to publish");
    }
    let base = options.registry.trim_end_matches('/').to_string();
    let publisher = mint.join("publish-crate.py");

    let mut token: Option<String> = None;
    let mut worst = CommandStatus::SUCCESS;
    let mut outcomes = Vec::new();
    for entry in &selected {
        let file = mint.join("crates").join(&entry.crate_file);
        let local = sha256_hex(&file)?;
        let index = crate::support::http::get_text_optional(&format!(
            "{base}/{}",
            index_path(&entry.name)
        ))?;
        let remote = match &index {
            Some(text) => index_cksum(text, &entry.wasix_version)?,
            None => None,
        };
        let (action, detail, published) = match classify(remote.as_deref(), &local) {
            Action::Skip => (
                Action::Skip,
                "already published, checksum matches".to_string(),
                false,
            ),
            Action::Conflict => {
                worst = worst.max(CommandStatus::FAILURE);
                (
                    Action::Conflict,
                    format!(
                        "the index serves different bytes for this version; mint a new \
                         one with `wasinix versions bump cargoRegistry.crates.{}@{}`",
                        entry.name, entry.upstream
                    ),
                    false,
                )
            }
            Action::Publish if options.effects.is_dry_run() => (
                Action::Publish,
                "would publish (dry run)".to_string(),
                false,
            ),
            Action::Publish => {
                if token.is_none() {
                    token = Some(crate::support::env::wasix_cargo_token()?.ok_or_else(|| {
                        crate::support::error::Error::Request(
                            "publishing needs WASIX_CARGO_TOKEN".into(),
                        )
                    })?);
                }
                let mut cmd = Command::new("python3");
                cmd.arg(&publisher)
                    .arg(&file)
                    .arg(&base)
                    .arg(token.as_deref().expect("token was just demanded"));
                crate::support::tools::log(&cmd);
                // One bad crate must not abort the rest; the failure lands in
                // the report and the exit code.
                match crate::support::tools::status(&mut cmd) {
                    Ok(status) if status.success() => {
                        (Action::Publish, "published".to_string(), true)
                    }
                    Ok(status) => {
                        worst = worst.max(CommandStatus::FAILURE);
                        (
                            Action::Publish,
                            format!("publish exited {}", status.code().unwrap_or(1)),
                            false,
                        )
                    }
                    Err(error) => {
                        worst = worst.max(CommandStatus::FAILURE);
                        (Action::Publish, format!("publish failed: {error}"), false)
                    }
                }
            }
        };
        outcomes.push(CrateOutcome {
            name: entry.name.clone(),
            version: entry.wasix_version.clone(),
            action,
            detail,
            published,
        });
    }
    Ok((
        PublishReport {
            registry: base,
            outcomes,
        },
        worst,
    ))
}

fn wait_ready(base: &str, server: &mut Child) -> Result<()> {
    for _ in 0..150 {
        if let Some(status) = server
            .try_wait()
            .map_err(|e| crate::support::error::io("wasmer", e))?
        {
            return request_error(format!("server exited early with {status}"));
        }
        if ureq::builder()
            .timeout(Duration::from_secs(2))
            .build()
            .get(&format!("{base}/config.json"))
            .call()
            .is_ok()
        {
            return Ok(());
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    request_error("server did not become ready")
}

/// A running instance that is torn down when this drops, however the caller
/// leaves: a stranded wasmer would hold the port.
struct Server {
    process: Child,
    _storage: Option<crate::support::fs::Scratch>,
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.process.kill();
        let _ = self.process.wait();
    }
}

pub struct ServeOptions {
    pub port: u16,
    pub data: Option<PathBuf>,
    /// A built mint to serve; built fresh when absent.
    pub mint: Option<PathBuf>,
    /// A built server package; built fresh when absent, which sandboxed
    /// checks cannot do.
    pub server: Option<PathBuf>,
    pub exec: Vec<String>,
}

/// A live local registry: the guard tears the server down on drop, so the
/// caller decides when to stop serving.
pub struct Running {
    server: Server,
    pub base: String,
}

impl Running {
    /// Whether the server process has exited on its own.
    pub fn exited(&mut self) -> Result<Option<std::process::ExitStatus>> {
        self.server
            .process
            .try_wait()
            .map_err(|e| crate::support::error::io("wasmer", e))
    }

    /// Block until the server exits (Ctrl-C stops it).
    pub fn wait(mut self) -> Result<CommandStatus> {
        let status = self
            .server
            .process
            .wait()
            .map_err(|e| crate::support::error::io("wasmer", e))?;
        Ok(CommandStatus::from_exit(status))
    }
}

pub fn serve(options: ServeOptions) -> Result<CommandStatus> {
    let exec = options.exec.clone();
    let running = start(options)?;
    if !exec.is_empty() {
        let mut cmd = Command::new(&exec[0]);
        cmd.args(&exec[1..]);
        let status = crate::support::tools::status(&mut cmd)?;
        return Ok(CommandStatus::from_exit(status));
    }
    ui::fact("stop", "Ctrl-C");
    running.wait()
}

/// Stand the registry up, seed it from the mint, and return the live guard.
pub fn start(options: ServeOptions) -> Result<Running> {
    let base = format!("http://127.0.0.1:{}", options.port);
    let token_hash = format!("{:x}", Sha256::digest(TOKEN.as_bytes()));

    let registry = mint_path(options.mint)?;
    let server_path = match options.server {
        Some(path) => path,
        None => {
            ui::fact("building", "the wasix server");
            nix_build(".#wasmerPackages.wasix-cargo-registry")?
        }
    };
    let manifest: Value = crate::support::json::read(&registry.join("manifest.json"))?;
    let wasm = server_path.join("bin/wasix-cargo-registry.wasm");
    let publisher = registry.join("publish-crate.py");

    // The mint is the point of serving; an empty one must not report itself
    // live and answer every resolve from crates.io.
    let mut crates: Vec<PathBuf> = std::fs::read_dir(registry.join("crates"))
        .map(|entries| {
            entries
                .flatten()
                .map(|entry| entry.path())
                .filter(|path| path.extension().is_some_and(|ext| ext == "crate"))
                .collect()
        })
        .unwrap_or_default();
    crates.sort();
    if crates.is_empty() {
        return request_error("the built registry holds no crates; nothing to serve");
    }

    let (data, storage) = match &options.data {
        Some(path) => {
            crate::support::fs::create_dir_all(path)?;
            (
                path.canonicalize()
                    .map_err(|e| crate::support::error::io(path, e))?,
                None,
            )
        }
        None => {
            let dir = crate::support::fs::Scratch::create("wasix-registry")?;
            (dir.path().to_path_buf(), Some(dir))
        }
    };

    // --volume, not --mapdir: durable writes need their fsync rights, or
    // publish hangs. 0.0.0.0 inside the guest, reached on loopback.
    let mut run = Command::new("wasmer");
    run.arg("run")
        .arg(&wasm)
        .args(["--net", "--enable-threads"])
        .arg("--volume")
        .arg(format!("{}:/data", data.display()))
        .args([
            "--env",
            &format!("REGISTRY_LISTEN_ADDR=0.0.0.0:{}", options.port),
            "--env",
            &format!("REGISTRY_BASE_URL={base}"),
            "--env",
            &format!("REGISTRY_AUTH_TOKEN_HASHES={token_hash}"),
            "--env",
            "REGISTRY_STORAGE_PATH=/data",
        ]);
    let process = crate::support::tools::spawn(&mut run)?;
    let mut server = Server {
        process,
        _storage: storage,
    };
    wait_ready(&base, &mut server.process)?;

    for path in &crates {
        let mut cmd = Command::new("python3");
        cmd.arg(&publisher).arg(path).args([&base, TOKEN]);
        let status = crate::support::tools::status(&mut cmd)?;
        if !status.success() {
            return request_error(format!("publishing {} failed", path.display()));
        }
    }

    let limits = manifest["shadowLimits"]
        .as_array()
        .cloned()
        .unwrap_or_default();
    for limit in &limits {
        let Some(name) = limit["crate"].as_str().filter(|name| !name.is_empty()) else {
            return request_error(format!("manifest shadow limit names no crate: {limit}"));
        };
        crate::support::http::put_json(
            &format!("{base}/api/v1/crates/{name}/shadow-limit"),
            &serde_json::json!({"limit": limit["limit"]}),
            Some(TOKEN),
        )?;
    }

    let builds = manifest["crates"].as_array().map(Vec::len).unwrap_or(0);
    ui::result(format!(
        "serving the overlay cargo registry · {builds} builds · {} shadow limits",
        limits.len()
    ));
    ui::result(format!("  url:   sparse+{base}/"));
    ui::result("  use:   .cargo/config.toml:");
    ui::result("           [source.crates-io]");
    ui::result("           replace-with = \"wasix\"");
    ui::result("           [source.wasix]");
    ui::result(format!("           registry = \"sparse+{base}/\""));

    Ok(Running { server, base })
}

pub struct PreviewOptions {
    /// The app name; demanded only when something will actually deploy.
    pub app: Option<String>,
    pub owner: String,
    /// The wasmer registry hosting the ephemeral app.
    pub registry: String,
    pub mint: Option<PathBuf>,
    /// A built base mint; when given, only crates whose bytes differ from it
    /// (or are new) deploy.
    pub base_mint: Option<PathBuf>,
    pub effects: crate::support::effects::Effects,
}

fn sparse_site(mint: &Path, site: &Path, base_url: &str, only: &[String]) -> Result<()> {
    let mut cmd = Command::new("python3");
    cmd.arg(mint.join("make-sparse-index.py"))
        .arg(mint)
        .arg(site)
        .args(["--base-url", base_url]);
    for spec in only {
        cmd.args(["--only", spec]);
    }
    crate::support::tools::checked_status(&mut cmd, "generating the sparse index")
}

/// Deploy the mint (or its diff against a base mint) as a static sparse
/// index on Edge. Returns the index URL and the served crate@version specs;
/// None when a base is given and nothing changed.
pub fn preview(options: PreviewOptions) -> Result<Option<(String, Vec<String>)>> {
    let mint = mint_path(options.mint)?;
    let manifest: Value = crate::support::json::read(&mint.join("manifest.json"))?;
    let entries: Vec<MintCrate> =
        serde_json::from_value(manifest["crates"].clone()).map_err(|source| {
            crate::support::error::Error::Json {
                path: mint.join("manifest.json").display().to_string().into(),
                source,
            }
        })?;
    // Minted tarballs are byte-reproducible, so bytes against the base mint
    // are the change signal: they fold the pin, the patches, and the rel
    // into exactly what would be served.
    let specs: Vec<String> = match &options.base_mint {
        None => entries
            .iter()
            .map(|entry| format!("{}@{}", entry.name, entry.wasix_version))
            .collect(),
        Some(base) => {
            let mut changed = Vec::new();
            for entry in &entries {
                let head_file = mint.join("crates").join(&entry.crate_file);
                let base_file = base.join("crates").join(&entry.crate_file);
                let head_bytes = std::fs::read(&head_file)
                    .map_err(|e| crate::support::error::io(&head_file, e))?;
                let same = match std::fs::read(&base_file) {
                    Ok(base_bytes) => base_bytes == head_bytes,
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => false,
                    Err(error) => return Err(crate::support::error::io(&base_file, error)),
                };
                if !same {
                    changed.push(format!("{}@{}", entry.name, entry.wasix_version));
                }
            }
            changed
        }
    };
    if specs.is_empty() {
        return Ok(None);
    }
    if options.effects.is_dry_run() {
        crate::support::ui::fact(
            "cargo preview",
            format!("would deploy {} crates (dry run)", specs.len()),
        );
        return Ok(None);
    }
    let app = options.app.as_deref().ok_or_else(|| {
        crate::support::error::Error::Request(
            "deploying a cargo preview needs --pull-request for the app name".into(),
        )
    })?;

    // The dl template needs the app's final URL, which only the deploy
    // reveals: deploy once to learn it, regenerate, redeploy in place.
    let scratch = crate::support::fs::Scratch::create("wasinix-cargo-preview")?;
    let site = scratch.path().join("site");
    sparse_site(&mint, &site, "http://unresolved.invalid", &specs)?;
    let url = crate::registries::edge::preview_site(crate::registries::edge::Site {
        site: &site,
        app,
        owner: &options.owner,
        registry: &options.registry,
    })?;
    std::fs::remove_dir_all(&site).map_err(|e| crate::support::error::io(&site, e))?;
    sparse_site(&mint, &site, &url, &specs)?;
    let final_url = crate::registries::edge::preview_site(crate::registries::edge::Site {
        site: &site,
        app,
        owner: &options.owner,
        registry: &options.registry,
    })?;
    Ok(Some((final_url, specs)))
}
