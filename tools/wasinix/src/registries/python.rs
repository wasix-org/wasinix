//! The python registry: publish the built index into its app's volume, deploy
//! PR previews as ephemeral Edge apps, serve an index locally, and count
//! which served wheels ship compiled extension modules.

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::Serialize;
use serde_json::Value;

use crate::support::error::{io, request_error, Result};
use crate::support::nix::{eval, Flake};
use crate::support::process::CommandStatus;
use crate::support::ui;

/// The registry a command talks to: the --registry flag, then
/// $WASMER_REGISTRY, then production. Anything but the default is a
/// deliberate choice: wasmer.io is production, wasmer.fun staging,
/// wasmer.wtf dev.
pub fn registry(flag: Option<&str>) -> String {
    flag.map(str::to_string)
        .unwrap_or_else(|| crate::support::env::wasmer_registry().expect("a set registry is unicode"))
}


/// The built index, or a fresh one when the caller named none.
fn registry_path(given: Option<PathBuf>) -> Result<PathBuf> {
    if let Some(path) = given {
        return Ok(path);
    }
    let paths = crate::support::nix::Invocation::flake("build", ".#pythonRegistry")
        .arg("--no-link")
        .out_paths("building the index")?;
    Ok(paths.into_iter().next_back().expect("out_paths is non-empty"))
}

pub struct Preview {
    /// The built site to serve.
    pub site: PathBuf,
    pub app: String,
    pub owner: String,
    pub registry: String,
}

/// Deploy a preview index as an ephemeral Edge app, and print its URL.
pub fn preview(request: Preview) -> Result<String> {
    crate::registries::edge::preview_site(crate::registries::edge::Site {
        site: &request.site,
        app: &request.app,
        owner: &request.owner,
        registry: &request.registry,
    })
}

pub struct Index {
    /// The built registry to publish; built fresh when absent.
    pub registry_path: Option<PathBuf>,
    /// The wasmer registry whose app volume receives the index.
    pub registry: String,
    pub rev: String,
    /// A dry run still exercises the credential and bucket path.
    pub effects: crate::support::effects::Effects,
    /// The checkout, which holds the app config and the publisher.
    pub repo: PathBuf,
    /// Upload the pages even when no wheel is new: they answer to the index
    /// generator rather than to the wheel set.
    pub refresh_listings: bool,
    /// Withdraw the pages of projects that no longer belong in simple/.
    pub withdraw_stale: bool,
}

/// The rclone config section the credentials come as. A volume without an S3
/// endpoint reports that on stdout and still exits 0, so what decides whether
/// they are there is the section, not the exit code.
fn rclone_section(text: &str) -> Option<&str> {
    text.lines().map(str::trim).find_map(|line| {
        line.strip_prefix('[')
            .and_then(|rest| rest.strip_suffix(']'))
    })
}

/// The app's volume credentials, as an rclone config. Reading works once the
/// volume has an S3 endpoint; a volume that has never had one is enabled here,
/// which provisions the credentials the read then returns.
fn volume_config(app_dir: &Path, registry: &str) -> Result<String> {
    let read = || -> Result<String> {
        let mut cmd = Command::new("wasmer");
        cmd.args(["app", "volume", "credentials"])
            .args(["--registry", registry])
            .args(["--format", "rclone"])
            .current_dir(app_dir);
        let output = crate::support::tools::output(&mut cmd)?;
        if !output.status.success() {
            return request_error(format!(
                "could not read the volume credentials: {}",
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    };
    let first = read()?;
    if rclone_section(&first).is_some() {
        return Ok(first);
    }
    let mut enable = Command::new("wasmer");
    enable
        .args(["app", "volume", "enable-s3"])
        .args(["--registry", registry])
        .current_dir(app_dir);
    crate::support::tools::log(&enable);
    if !crate::support::tools::status(&mut enable)?.success() {
        return request_error("could not enable the volume's S3 endpoint");
    }
    read()
}

/// Publish the built index into the app's volume.
///
/// The app is identified by pkgs/python-registry/app.yaml, so no name has to
/// resolve on the selected registry. The credentials live in a config of
/// their own for the length of the run, rather than in the caller's
/// rclone.conf, which would leave a working key in a home directory.
pub fn publish_index(request: Index) -> Result<CommandStatus> {
    let registry_path = registry_path(request.registry_path)?;
    let app_dir = request.repo.join("pkgs/python-registry");
    let registry = request.registry;
    let scratch = crate::support::fs::Scratch::create("wasinix-rclone")?;
    let config = scratch.path().join("rclone.conf");
    let section = volume_config(&app_dir, &registry)?;
    crate::support::fs::write(&config, section.as_bytes())?;

    // The section name is `edge-<app>-<volume>` mangled by the CLI, so it is
    // read back rather than reconstructed.
    let Some(remote) = rclone_section(&section) else {
        return request_error("no rclone remote section in the credentials output");
    };

    // The volume's bucket is a per-deploy id, and the endpoint holds exactly
    // one, so it is discovered rather than named. The retry bounds are what
    // turn an endpoint that never answers into a message rather than a hang.
    let mut list = Command::new("rclone");
    list.arg("lsd")
        .arg(format!("{remote}:"))
        .args(["--contimeout", "30s"])
        .args(["--timeout", "60s"])
        .args(["--retries", "1"])
        .args(["--low-level-retries", "1"])
        .env("RCLONE_CONFIG", &config);
    let listed = crate::support::tools::output(&mut list)?;
    let bucket = String::from_utf8_lossy(&listed.stdout)
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().next_back().map(str::to_string));
    let Some(bucket) = bucket.filter(|bucket| !bucket.is_empty()) else {
        return request_error(format!(
            "the volume's endpoint listed no S3 bucket: {}",
            crate::support::error::tail(&String::from_utf8_lossy(&listed.stderr), 300)
        ));
    };

    let mut publish = Command::new("python3");
    publish
        .arg(app_dir.join("publish.py"))
        .arg("--registry")
        .arg(&registry_path)
        .args(["--remote", &format!("{remote}:{bucket}")])
        .args(["--rev", &request.rev]);
    if request.effects.is_dry_run() {
        publish.arg("--dry-run");
    }
    if request.refresh_listings {
        publish.arg("--refresh-listings");
    }
    if request.withdraw_stale {
        publish.arg("--withdraw-stale");
    }
    publish
        .env("RCLONE_CONFIG", &config)
        .current_dir(&request.repo);
    crate::support::tools::log(&publish);
    if !crate::support::tools::status(&mut publish)?.success() {
        return request_error("publishing the index failed");
    }
    Ok(CommandStatus::SUCCESS)
}

/// Serve a built (or local) index over plain HTTP, the same layout pip
/// resolves from the deployed app.
/// A live local index server; dropped, it stops serving.
pub struct Running {
    child: std::process::Child,
    pub url: String,
}

impl Running {
    pub fn exited(&mut self) -> Result<Option<std::process::ExitStatus>> {
        self.child
            .try_wait()
            .map_err(|e| crate::support::error::io("python3", e))
    }

    pub fn wait(mut self) -> Result<CommandStatus> {
        let status = self
            .child
            .wait()
            .map_err(|e| crate::support::error::io("python3", e))?;
        Ok(CommandStatus::from_exit(status))
    }
}

impl Drop for Running {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Start serving a built (or local) index over plain HTTP, the same layout
/// pip resolves from the deployed app.
pub fn start(given: Option<PathBuf>, port: u16) -> Result<Running> {
    let root = registry_path(given)?;
    if !root.join("simple").is_dir() {
        return request_error(format!(
            "{}: no simple/ dir, not a python index",
            root.display()
        ));
    }
    let url = format!("http://127.0.0.1:{port}/simple");
    ui::result(format!("serving the built index at {}", root.display()));
    ui::result(format!("  url:   {url}"));
    ui::result(format!(
        "  use:   pip install --index-url {url} <package>"
    ));
    let mut cmd = Command::new("python3");
    cmd.args(["-m", "http.server", &port.to_string(), "--directory"])
        .arg(&root);
    let child = crate::support::tools::spawn(&mut cmd)?;
    let mut running = Running { child, url };
    // "Started" means answering: a consumer probing right after start must
    // not race the listener.
    for _ in 0..150 {
        if let Some(status) = running.exited()? {
            return request_error(format!("the index server exited early with {status}"));
        }
        if ureq::builder()
            .timeout(std::time::Duration::from_secs(2))
            .build()
            .get(&running.url)
            .call()
            .is_ok()
        {
            return Ok(running);
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
    request_error("the index server did not become ready")
}

pub fn serve(given: Option<PathBuf>, port: u16) -> Result<CommandStatus> {
    let running = start(given, port)?;
    ui::fact("stop", "Ctrl-C");
    running.wait()
}

const WASM_MAGIC: &[u8; 4] = b"\0asm";

/// Whether a wheel carries a wasm binary: usually a `.so`, which on this
/// target is a wasm32 extension module, but a bundled program has no telling
/// suffix, so the file's own magic decides when the name does not. A member
/// that cannot be read fails the read: a corrupt wheel must not classify as
/// pure.
fn is_native(path: &Path) -> Result<bool> {
    let file = std::fs::File::open(path).map_err(|e| io(path, e))?;
    let mut archive = zip::ZipArchive::new(file).map_err(|error| {
        crate::support::error::Error::Request(format!("{}: {error}", path.display()))
    })?;
    if (0..archive.len()).any(|index| {
        archive
            .name_for_index(index)
            .is_some_and(|name| name.ends_with(".so"))
    }) {
        return Ok(true);
    }
    for index in 0..archive.len() {
        let mut member = archive.by_index(index).map_err(|error| {
            crate::support::error::Error::Request(format!("{}: {error}", path.display()))
        })?;
        if member.is_dir() {
            continue;
        }
        let mut magic = [0u8; 4];
        if member.read_exact(&mut magic).is_ok() && &magic == WASM_MAGIC {
            return Ok(true);
        }
    }
    Ok(false)
}

#[derive(Debug, Default, Serialize, serde::Deserialize)]
pub struct NativeKind {
    pub projects: Vec<String>,
    pub files: usize,
}

#[derive(Debug, Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NativeReport {
    pub registry: String,
    pub native: NativeKind,
    pub pure: NativeKind,
}

impl crate::support::schema::Document for NativeReport {
    const KIND: &'static str = "nativeWheels";
    const SCHEMA: u32 = 1;
}

pub fn count_natives(given: Option<PathBuf>) -> Result<NativeReport> {
    let root = registry_path(given)?;
    let simple = root.join("simple");
    if !simple.is_dir() {
        return request_error(format!(
            "{}: no simple/ dir, not a python index",
            root.display()
        ));
    }
    // <project>/<wheel>.whl, the layout a PEP 503 index serves.
    let mut wheels: BTreeMap<String, Vec<PathBuf>> = BTreeMap::new();
    for project in std::fs::read_dir(&simple).map_err(|e| io(&simple, e))? {
        let project = project.map_err(|e| io(&simple, e))?;
        if !project.file_type().map_err(|e| io(&simple, e))?.is_dir() {
            continue;
        }
        let project_path = project.path();
        for entry in std::fs::read_dir(&project_path).map_err(|e| io(&project_path, e))? {
            let entry = entry.map_err(|e| io(&project_path, e))?;
            if entry.path().extension().is_some_and(|ext| ext == "whl") {
                wheels
                    .entry(project.file_name().to_string_lossy().into_owned())
                    .or_default()
                    .push(entry.path());
            }
        }
    }

    let mut report = NativeReport {
        registry: root.display().to_string(),
        native: NativeKind::default(),
        pure: NativeKind::default(),
    };
    for (project, files) in wheels {
        // One native wheel makes the project native: a pure build of the same
        // release would be the exception, not the rule.
        let mut native = false;
        for file in &files {
            native |= is_native(file)?;
        }
        let kind = if native {
            &mut report.native
        } else {
            &mut report.pure
        };
        kind.projects.push(project);
        kind.files += files.len();
    }
    Ok(report)
}

/// What a change would publish, for PR previews: two checkouts' build plans
/// compared by derivation.
#[derive(Debug, Serialize)]
pub struct PlanWebc {
    pub attr: String,
    pub owner: String,
    pub name: String,
    pub version: String,
}

#[derive(Debug, Serialize)]
pub struct PlanDiff {
    pub wheels: Vec<Value>,
    pub webcs: Vec<PlanWebc>,
}

/// attr is the wasmerPackages key (jq-1.6.0 for a history entry); owner and
/// name are the identity it publishes under (wasmer/jq).
fn webc_drvs_apply() -> String {
    crate::support::nix::canonical_webcs_apply(
        "_: p: { drv = p.pkg.drvPath; owner = p.pkg.id.owner; \
         name = p.pkg.id.name; version = p.pkg.id.baseVersion; }",
    )
}

fn dists(flake: &Flake<'_>) -> Result<BTreeMap<String, Value>> {
    // distsJson is a JSON string, not a structure: it is written for
    // consumers outside nix.
    let raw = eval(flake, "pythonRegistry.distsJson", None)?;
    let parsed: Value = match raw.as_str() {
        Some(text) => serde_json::from_str(text).map_err(|source| {
            crate::support::error::Error::Json {
                path: "<pythonRegistry.distsJson>".into(),
                source,
            }
        })?,
        None => raw,
    };
    Ok(parsed
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|dist| {
            dist["attr"]
                .as_str()
                .map(|attr| (attr.to_string(), dist.clone()))
        })
        .collect())
}

/// Build the preview index site: the changed wheels only, their versions
/// suffixed so the overlay outranks the published index.
pub fn preview_index(
    repo: &Path,
    wheels: &[Value],
    suffix: &str,
    scratch: &Path,
    site: &Path,
) -> Result<()> {
    // Each wheel is published a second time under a longer local version. The
    // suffix is an argument to the wheel's own publish derivation, so a preview
    // wheel is made the same way a released one is.
    let mut suffixed = Vec::with_capacity(wheels.len());
    for wheel in wheels {
        let attr = wheel["attr"].as_str().ok_or_else(|| {
            crate::support::error::Error::Request("a changed wheel has no attr".into())
        })?;
        let base = attr.strip_suffix("^dist").unwrap_or(attr);
        let expr = format!(
            r#"(builtins.getFlake "path:{repo}").legacyPackages.{system}.{base}.publishedWith "{suffix}""#,
            repo = repo.display(),
            system = crate::support::nix::SYSTEM,
        );
        let built = crate::support::nix::Invocation::expr("build", expr)
            .impure()
            .arg("--no-link")
            .arg("--print-out-paths")
            .accepts_flake_config()
            .workdir(repo)
            .probe("a failing preview wheel build reports its own stderr")?;
        if !built.status.is_success() {
            return request_error(format!(
                "building the preview wheel {attr} failed: {}",
                crate::support::tools::diagnostics_tail(&built.stderr)
            ));
        }
        let out = String::from_utf8_lossy(&built.stdout).trim().to_string();
        if out.is_empty() {
            return request_error(format!("the preview wheel {attr} built to no output path"));
        }
        let mut entry = wheel.clone();
        entry["published"] = Value::String(out);
        suffixed.push(entry);
    }

    let dists = scratch.join("dists.json");
    crate::support::json::write(&dists, &Value::Array(suffixed))?;
    let mut index = Command::new("python3");
    index
        .arg(repo.join("pkgs/python-registry/make-index.py"))
        .arg(&dists)
        .arg(site)
        .current_dir(repo);
    crate::support::tools::log(&index);
    if !crate::support::tools::status(&mut index)?.success() {
        return request_error("building the preview index failed");
    }
    Ok(())
}

pub fn plan_diff(base_dir: &str) -> Result<PlanDiff> {
    let base = format!("path:{base_dir}");
    let base = Flake(&base);
    let head = Flake::default();

    let head_dists = dists(&head)?;
    let base_dists = dists(&base)?;
    let wheels = head_dists
        .iter()
        .filter(|(attr, dist)| {
            base_dists.get(*attr).map(|base| &base["drvPath"]) != Some(&dist["drvPath"])
        })
        .map(|(_, dist)| dist.clone())
        .collect();

    let webc_apply = webc_drvs_apply();
    let head_webcs = eval(&head, "wasmerPackages", Some(&webc_apply))?;
    let base_webcs = eval(&base, "wasmerPackages", Some(&webc_apply))?;
    let webcs = head_webcs
        .as_object()
        .into_iter()
        .flatten()
        .filter(|(attr, webc)| base_webcs[*attr]["drv"] != webc["drv"])
        .map(|(attr, webc)| PlanWebc {
            attr: attr.clone(),
            owner: webc["owner"].as_str().unwrap_or_default().to_string(),
            name: webc["name"].as_str().unwrap_or_default().to_string(),
            version: webc["version"].as_str().unwrap_or_default().to_string(),
        })
        .collect();

    Ok(PlanDiff { wheels, webcs })
}
