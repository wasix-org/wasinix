//! The wasmer registry: build shipped webc packages and publish the ones the
//! registry lacks.
//!
//! Registry versions are immutable and there is no webc rel encoding yet, so a
//! version that already exists is verified rather than replaced: the local
//! build is restaged with the rev the published README records, and its hash
//! must match. Packages publish in dependency order, and a dependency that is
//! neither published nor part of the run is an error rather than a broken
//! artifact.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

use crate::support::error::{request_error, Error, Result};
use crate::support::naming::{self, Domain};
use crate::support::nix::{Flake, SYSTEM};

/// The rebuild command doubles as the machine-readable rev record: the
/// appended block is a pure function of (package dir, rev), so a later run
/// reproduces the published bytes by restaging with the recorded rev.
static REV: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(?m)^    nix build 'github:wasix-org/wasinix/([^#']+)#").unwrap()
});

#[derive(Debug, Clone)]
pub struct Package {
    pub full_name: String,
    pub version: String,
    pub path: PathBuf,
    /// webc `[dependencies]`: full name -> version.
    pub dependencies: BTreeMap<String, String>,
    /// Repo-relative "path:line" of the package definition, for the published
    /// README's pinned source link.
    pub source: Option<String>,
}

impl Package {
    fn key(&self) -> (String, String) {
        (self.full_name.clone(), self.version.clone())
    }
}

#[derive(Debug, Default, Clone)]
pub struct Published {
    pub exists: bool,
    pub webc_sha256: Option<String>,
    pub readme: Option<String>,
}

/// A per-package failure: recorded, and the run continues.
fn package_error<T>(message: impl Into<String>) -> Result<T> {
    Err(Error::Request(message.into()))
}

/// The shared checked runner, demoted to a per-package failure so one bad
/// publish does not abort the rest.
fn run(cmd: &mut Command) -> Result<()> {
    crate::support::tools::checked_status(cmd, "publishing")
        .map_err(|error| Error::Request(error.to_string()))
}

/// Canonical shipped webc names with every accepted alias.
fn webc_domain() -> Result<Domain> {
    let apply = crate::support::nix::canonical_webcs_apply(
        "_: p: { overlay = p.overlayName; aliases = p.passthru.wasmer.aliases or []; }",
    );
    let named = crate::support::nix::eval(
        &Flake::default(),
        "wasmerPackages",
        Some(&apply),
    )?;
    let mut domain = Domain::new(".#wasmerPackages");
    for (webc, info) in named.as_object().into_iter().flatten() {
        let mut aliases = vec![info["overlay"].as_str().unwrap_or_default().to_string()];
        aliases.extend(
            info["aliases"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|alias| alias.as_str().map(str::to_string)),
        );
        domain.add_path(
            vec!["wasmerPackages".into(), webc.clone()],
            webc,
            None,
            aliases,
        );
    }
    Ok(domain)
}

/// Names to publish. A version cannot be picked: what publishes is what the
/// checkout ships.
fn selected_packages(specs: &[String]) -> Result<Vec<String>> {
    if specs.is_empty() {
        return Ok(Vec::new());
    }
    let mut names = Vec::new();
    for resolved in naming::resolve_all(&webc_domain()?, specs)? {
        if resolved.value.is_some() {
            return request_error(format!(
                "{}: publish-webc publishes the version this checkout ships",
                resolved.address()
            ));
        }
        names.push(resolved.key);
    }
    Ok(names)
}

fn build_pkg_roots(selected: &[String]) -> Result<Vec<PathBuf>> {
    let prefix = format!(".#legacyPackages.{SYSTEM}");
    let mut installables: Vec<String> = Vec::new();
    if selected.is_empty() {
        installables.push(format!("{prefix}.allWasmerPackages"));
    } else {
        let mut seen = BTreeSet::new();
        for name in selected {
            if seen.insert(name.clone()) {
                // Quoted: a webc name may contain dots (python3.14).
                installables.push(format!(
                    "{prefix}.wasmerPackages.{}.pkg",
                    naming::quoted_attr(name)?
                ));
            }
        }
    }
    crate::support::ui::fact("building", installables.join(" "));
    let paths = crate::support::nix::Invocation::plain("build")
        .accepts_flake_config()
        .args(["-L", "--no-link"])
        .operands(installables)
        .out_paths("building the packages")?;
    Ok(paths.into_iter().map(|path| path.join("pkg")).collect())
}

fn normalize_registry(registry: &str) -> String {
    let registry = registry.trim().trim_end_matches('/');
    if registry.starts_with("http://") || registry.starts_with("https://") {
        registry.to_string()
    } else {
        format!("https://{registry}")
    }
}

fn split_registry(registry: &str) -> Result<(String, String)> {
    let normalized = normalize_registry(registry);
    let Some((scheme, rest)) = normalized.split_once("://") else {
        return request_error(format!("Invalid registry value: {registry}"));
    };
    let host = rest.split('/').next().unwrap_or_default();
    if host.is_empty() {
        return request_error(format!("Invalid registry value: {registry}"));
    }
    Ok((scheme.to_string(), host.to_string()))
}

/// The GraphQL endpoint lives on the registry subdomain.
pub fn graphql_endpoint(registry: &str) -> Result<String> {
    let (scheme, host) = split_registry(registry)?;
    let graphql_host = if host.starts_with("registry.") {
        host
    } else {
        format!("registry.{host}")
    };
    Ok(format!("{scheme}://{graphql_host}/graphql"))
}

/// `wasmer publish` wants the bare host, not the registry subdomain.
pub fn publish_registry(registry: &str) -> Result<String> {
    let (_, host) = split_registry(registry)?;
    Ok(host.strip_prefix("registry.").unwrap_or(&host).to_string())
}

/// Keyed by (name, version): one name serves several versions through registry
/// history, each its own immutable package version.
pub fn read_packages(roots: &[PathBuf]) -> Result<BTreeMap<(String, String), Package>> {
    let mut packages: BTreeMap<(String, String), Package> = BTreeMap::new();
    for root in roots {
        if !root.is_dir() {
            return request_error(format!(
                "Package directory does not exist: {}",
                root.display()
            ));
        }
        for manifest in find_manifests(root) {
            let text = crate::support::fs::read_to_string(&manifest)?;
            let data: toml::Value = toml::from_str(&text)
                .map_err(|error| Error::Request(format!("{}: {error}", manifest.display())))?;
            let package = data.get("package");
            let full_name = package
                .and_then(|p| p.get("name"))
                .and_then(toml::Value::as_str);
            let version = package
                .and_then(|p| p.get("version"))
                .and_then(toml::Value::as_str);
            let (Some(full_name), Some(version)) = (full_name, version) else {
                return request_error(format!(
                    "Missing/invalid package.name or package.version in {}",
                    manifest.display()
                ));
            };
            let mut dependencies = BTreeMap::new();
            if let Some(table) = data.get("dependencies") {
                let Some(table) = table.as_table() else {
                    return request_error(format!(
                        "Invalid [dependencies] in {}",
                        manifest.display()
                    ));
                };
                for (name, value) in table {
                    let Some(value) = value.as_str() else {
                        return request_error(format!(
                            "Invalid [dependencies] in {}",
                            manifest.display()
                        ));
                    };
                    dependencies.insert(name.clone(), value.to_string());
                }
            }
            let key = (full_name.to_string(), version.to_string());
            if let Some(existing) = packages.get(&key) {
                return request_error(format!(
                    "Duplicate package {full_name}@{version} in {} and {}",
                    manifest.display(),
                    existing.path.join("wasmer.toml").display()
                ));
            }
            let metadata = package.and_then(|p| p.get("metadata"));
            packages.insert(
                key,
                Package {
                    full_name: full_name.to_string(),
                    version: version.to_string(),
                    path: manifest.parent().unwrap_or(root).to_path_buf(),
                    dependencies,
                    source: metadata
                        .and_then(|m| m.get("wasix-source"))
                        .and_then(toml::Value::as_str)
                        .map(str::to_string),
                },
            );
        }
    }
    if packages.is_empty() {
        return request_error("No packages found under the built roots");
    }
    Ok(packages)
}

fn find_manifests(root: &Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else if path.file_name().is_some_and(|name| name == "wasmer.toml") {
                found.push(path);
            }
        }
    }
    found.sort();
    found
}

/// Dependencies first, then (name, version) order so a run is deterministic.
pub fn order_packages(packages: &BTreeMap<(String, String), Package>) -> Result<Vec<Package>> {
    let mut ordered = Vec::new();
    let mut done: BTreeSet<(String, String)> = BTreeSet::new();

    fn visit(
        key: &(String, String),
        packages: &BTreeMap<(String, String), Package>,
        done: &mut BTreeSet<(String, String)>,
        ordered: &mut Vec<Package>,
        chain: &mut Vec<(String, String)>,
    ) -> Result<()> {
        if done.contains(key) {
            return Ok(());
        }
        if chain.contains(key) {
            let pretty: Vec<String> = chain
                .iter()
                .chain(std::iter::once(key))
                .map(|(name, version)| format!("{name}@{version}"))
                .collect();
            return request_error(format!("Dependency cycle: {}", pretty.join(" -> ")));
        }
        chain.push(key.clone());
        for (name, version) in &packages[key].dependencies {
            let dep = (name.clone(), version.clone());
            if packages.contains_key(&dep) {
                visit(&dep, packages, done, ordered, chain)?;
            }
        }
        chain.pop();
        done.insert(key.clone());
        ordered.push(packages[key].clone());
        Ok(())
    }

    for key in packages.keys() {
        visit(key, packages, &mut done, &mut ordered, &mut Vec::new())?;
    }
    Ok(ordered)
}

pub fn normalize_sha256(value: Option<&str>) -> Option<String> {
    let candidate = value?.trim().to_lowercase();
    (candidate.len() == 64 && candidate.chars().all(|c| c.is_ascii_hexdigit())).then_some(candidate)
}

fn sha256_file(path: &Path) -> Result<String> {
    use std::io::Read;
    let mut file = std::fs::File::open(path).map_err(|e| crate::support::error::io(path, e))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1024 * 1024];
    loop {
        let read = file
            .read(&mut buffer)
            .map_err(|e| crate::support::error::io(path, e))?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Result<Scratch> {
        let path = crate::support::env::temp_dir().join(format!("publish-webc-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        crate::support::fs::create_dir_all(&path)?;
        Ok(Scratch(path))
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn build_webc_sha256(pkg_dir: &Path, pkg: &Package) -> Result<String> {
    let scratch = Scratch::new("build")?;
    let out = scratch.0.join("package.webc");
    run(Command::new("wasmer")
        .args(["package", "build", "--quiet", "--out"])
        .arg(&out)
        .arg(".")
        .current_dir(pkg_dir))?;
    if !out.is_file() {
        return package_error(format!(
            "expected local .webc output missing for {}@{}: {}",
            pkg.full_name,
            pkg.version,
            out.display()
        ));
    }
    sha256_file(&out)
}

const QUERY: &str = "query GetPackageVersion($name: String!, $version: String!) { \
    getPackageVersion(name: $name, version: $version) { \
    id readme distribution { webcSha256Hash piritaSha256Hash } \
    packagewebcSet(first: 1) { edges { node { tag webc { webcSha256 } webcV3 { webcSha256 } } } } } }";

pub fn get_published(graphql_url: &str, full_name: &str, version: &str) -> Result<Published> {
    let payload = json!({
        "query": QUERY,
        "variables": {"name": full_name, "version": version},
        "operationName": "GetPackageVersion",
    });
    // Transport failures are fatal; a resolver error below is not.
    let document: Value = crate::support::http::post_json(graphql_url, &payload)?;
    if let Some(errors) = document.get("errors").filter(|errors| !errors.is_null()) {
        if !errors.as_array().is_some_and(Vec::is_empty) {
            return package_error(format!(
                "GraphQL returned errors for {full_name}@{version}: {errors}"
            ));
        }
    }
    let Some(data) = document.get("data").filter(|data| data.is_object()) else {
        return request_error(format!(
            "GraphQL response missing data for {full_name}@{version}: {document}"
        ));
    };
    let version_node = &data["getPackageVersion"];
    if version_node.is_null() {
        return Ok(Published::default());
    }
    if !version_node.is_object() {
        return request_error(format!(
            "GraphQL getPackageVersion has unexpected shape for {full_name}@{version}: {version_node}"
        ));
    }

    let mut webc_sha256 = None;
    for edge in version_node["packagewebcSet"]["edges"]
        .as_array()
        .into_iter()
        .flatten()
    {
        let node = &edge["node"];
        webc_sha256 = normalize_sha256(node["webcV3"]["webcSha256"].as_str())
            .or_else(|| normalize_sha256(node["webc"]["webcSha256"].as_str()))
            .or_else(|| normalize_sha256(node["tag"].as_str()));
        if webc_sha256.is_some() {
            break;
        }
    }
    if webc_sha256.is_none() {
        let distribution = &version_node["distribution"];
        webc_sha256 = normalize_sha256(distribution["webcSha256Hash"].as_str())
            .or_else(|| normalize_sha256(distribution["piritaSha256Hash"].as_str()));
    }
    Ok(Published {
        exists: true,
        webc_sha256,
        readme: version_node["readme"].as_str().map(str::to_string),
    })
}

pub fn recorded_rev(readme: Option<&str>) -> Option<String> {
    REV.captures(readme?)
        .map(|captured| captured[1].to_string())
}

fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    use crate::support::error::io;
    crate::support::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from).map_err(|e| io(from, e))?.flatten() {
        let source = entry.path();
        let target = to.join(entry.file_name());
        if source.is_dir() {
            copy_tree(&source, &target)?;
        } else {
            std::fs::copy(&source, &target).map_err(|e| io(&target, e))?;
            // The store is read-only, and staging rewrites these files.
            let mut permissions = std::fs::metadata(&target)
                .map_err(|e| io(&target, e))?
                .permissions();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                permissions.set_mode(permissions.mode() | 0o200);
            }
            std::fs::set_permissions(&target, permissions).map_err(|e| io(&target, e))?;
        }
    }
    Ok(())
}

pub fn provenance(pkg: &Package, rev: &str) -> String {
    let name = pkg
        .full_name
        .split_once('/')
        .map(|(_, name)| name)
        .unwrap_or(&pkg.full_name);
    let origin = match &pkg.source {
        Some(source) => {
            let (file, line) = source.rsplit_once(':').unwrap_or((source.as_str(), "1"));
            format!("Built from [{file}](https://github.com/wasix-org/wasinix/blob/{rev}/{file}#L{line})")
        }
        None => "Built by [wasinix](https://github.com/wasix-org/wasinix)".to_string(),
    };
    let short: String = rev.chars().take(12).collect();
    format!(
        "\n{origin}\nat `{short}`; rebuild with\n\n    nix build 'github:wasix-org/wasinix/{rev}#wasmerPackages.\"{name}\".webc'\n"
    )
}

#[allow(clippy::too_many_arguments)]
pub fn stage(
    pkg: &Package,
    rev: &str,
    into: &Path,
    pub_name: &str,
    pub_version: &str,
    preview_tag: Option<&str>,
    batch: &BTreeSet<(String, String)>,
) -> Result<PathBuf> {
    let dst = into.join("pkg");
    copy_tree(&pkg.path, &dst)?;
    // `wasmer publish` reads the identity out of the manifest, so a preview
    // tag or a one-off `--as` has to be written into the staged copy. Batch
    // dependency pins follow the preview tag so its references resolve.
    let renamed = pub_name != pkg.full_name || pub_version != pkg.version;
    if renamed || preview_tag.is_some() {
        let manifest = dst.join("wasmer.toml");
        let original = crate::support::fs::read_to_string(&manifest)?;
        let mut text = original.replacen(
            &format!("name = \"{}\"", pkg.full_name),
            &format!("name = \"{pub_name}\""),
            1,
        );
        text = text.replacen(
            &format!("version = \"{}\"", pkg.version),
            &format!("version = \"{pub_version}\""),
            1,
        );
        // A manifest spelling the identity some other way would leave the
        // staged copy under the old one while every registry call uses the
        // new one, publishing the wrong package.
        if renamed && text == original {
            return package_error(format!(
                "{}: no `name`/`version` line to rewrite for {pub_name}@{pub_version}",
                manifest.display()
            ));
        }
        if let Some(tag) = preview_tag {
            for (dep, version) in &pkg.dependencies {
                if batch.contains(&(dep.clone(), version.clone())) {
                    text = text.replacen(
                        &format!("\"{dep}\" = \"{version}\""),
                        &format!("\"{dep}\" = \"{version}-{tag}\""),
                        1,
                    );
                }
            }
        }
        crate::support::fs::write(&manifest, text.as_bytes())?;
    }
    let readme = dst.join("README.md");
    let mut text = std::fs::read_to_string(&readme).unwrap_or_default();
    text.push_str(&provenance(pkg, rev));
    crate::support::fs::write(&readme, text.as_bytes())?;
    Ok(dst)
}

fn staged_sha256(
    pkg: &Package,
    rev: &str,
    pub_name: &str,
    pub_version: &str,
) -> Result<String> {
    let scratch = Scratch::new("restage")?;
    let staged = stage(
        pkg,
        rev,
        &scratch.0,
        pub_name,
        pub_version,
        None,
        &BTreeSet::new(),
    )?;
    build_webc_sha256(&staged, pkg)
}

/// `wasmer publish` can exit 0 without tagging anything, so re-query until the
/// version shows up; the retries also cover indexing lag.
fn verify_published(
    graphql_url: &str,
    full_name: &str,
    version: &str,
    expected: &str,
) -> Result<()> {
    let mut info = Published::default();
    for attempt in 0..5 {
        info = get_published(graphql_url, full_name, version)?;
        if info.exists {
            break;
        }
        if attempt < 4 {
            std::thread::sleep(std::time::Duration::from_secs(5));
        }
    }
    if !info.exists {
        return package_error(
            "wasmer publish reported success, but the version is not visible in the registry (silent no-op?)",
        );
    }
    match &info.webc_sha256 {
        Some(published) if published != expected => package_error(format!(
            "published, but the registry stored different content: local={expected} registry={published}"
        )),
        Some(_) => Ok(()),
        None => {
            crate::support::ui::warning(format!(
                "registry returned no hash for {full_name}@{version}; cannot cross-check the published content"
            ));
            Ok(())
        }
    }
}

/// A one-off publish identity, `[<namespace>/]<name>[@<version>]`. Every
/// part is optional; what the spec omits keeps the manifest's value.
#[derive(Debug, Default, PartialEq)]
pub struct PublishAs {
    /// Either `namespace/name` or a bare name replacing only that segment.
    name: Option<String>,
    version: Option<String>,
}

pub fn parse_publish_as(spec: &str) -> Result<PublishAs> {
    if spec.chars().any(char::is_whitespace) {
        return request_error(format!("--as {spec}: an identity holds no whitespace"));
    }
    let (name, version) = match spec.split_once('@') {
        Some((name, version)) => (name, Some(version)),
        None => (spec, None),
    };
    if version.is_some_and(str::is_empty) {
        return request_error(format!("--as {spec}: the version after `@` is empty"));
    }
    if name.matches('/').count() > 1 {
        return request_error(format!("--as {spec}: a name is `namespace/name`"));
    }
    if name.split('/').any(str::is_empty) && !name.is_empty() {
        return request_error(format!("--as {spec}: a name segment is empty"));
    }
    let parsed = PublishAs {
        name: (!name.is_empty()).then(|| name.to_string()),
        version: version.map(str::to_string),
    };
    if parsed == PublishAs::default() {
        return request_error("--as: the identity overrides nothing");
    }
    Ok(parsed)
}

impl PublishAs {
    /// The identity to publish `pkg` under. A bare name keeps the manifest's
    /// namespace, so `--as python` renames within the same namespace.
    pub fn apply(&self, pkg: &Package) -> (String, String) {
        let name = match &self.name {
            Some(name) if name.contains('/') => name.clone(),
            Some(name) => match pkg.full_name.split_once('/') {
                Some((namespace, _)) => format!("{namespace}/{name}"),
                None => name.clone(),
            },
            None => pkg.full_name.clone(),
        };
        let version = self.version.clone().unwrap_or_else(|| pkg.version.clone());
        (name, version)
    }
}

pub struct Options {
    pub registry: String,
    pub packages: Vec<String>,
    pub effects: crate::support::effects::Effects,
    pub skip_sha_validation: bool,
    pub rev: Option<String>,
    pub preview: Option<String>,
    pub publish_as: Option<String>,
}

pub fn publish(options: Options) -> Result<crate::support::process::CommandStatus> {
    let rev = match &options.rev {
        Some(rev) if !rev.is_empty() => rev.clone(),
        _ => {
            // The recorded provenance must come from the checkout being
            // published, not whatever cwd invoked the binary.
            let repo = crate::support::git::repo_root()?;
            let mut rev = crate::support::git::git(&repo, &["rev-parse", "HEAD"])?;
            let clean = crate::support::git::git(&repo, &["diff-index", "--quiet", "HEAD"]);
            if clean.is_err() {
                rev.push_str("-dirty");
            }
            rev
        }
    };

    let publish_as = options
        .publish_as
        .as_deref()
        .map(parse_publish_as)
        .transpose()?;
    // The exact count needs the built roots, but an empty selection means
    // every shipped package; refusing here saves that build.
    if publish_as.is_some() && options.packages.is_empty() {
        return request_error("--as needs exactly one package; none selected means all shipped");
    }
    let packages = read_packages(&build_pkg_roots(&selected_packages(&options.packages)?)?)?;
    let ordered = order_packages(&packages)?;
    // One identity cannot name several packages, and a renamed dependency
    // would leave its dependents pinned to a name the registry lacks.
    if publish_as.is_some() && ordered.len() != 1 {
        return request_error(format!(
            "--as needs exactly one package; {} selected",
            ordered.len()
        ));
    }
    let graphql_url = graphql_endpoint(&options.registry)?;
    let publish_host = publish_registry(&options.registry)?;
    crate::support::ui::fact("packages", ordered.len());
    crate::support::ui::fact(
        "registry",
        format!("{} (graphql: {graphql_url}, publish: {publish_host})", options.registry),
    );
    if options.effects.is_dry_run() {
        crate::support::ui::fact("mode", "dry run; nothing publishes");
    }
    if options.skip_sha_validation {
        crate::support::ui::fact("sha validation", "off for already-published versions");
    }

    let batch: BTreeSet<(String, String)> = packages.keys().cloned().collect();
    // Resolvable for dependents: already published (even with a hash
    // mismatch), published this run, or would-publish in a dry run.
    let mut available: BTreeSet<(String, String)> = BTreeSet::new();
    let mut published = 0;
    let mut skipped = 0;
    let mut failures: Vec<String> = Vec::new();

    for pkg in &ordered {
        let (pub_name, mut pub_version) = match &publish_as {
            Some(publish_as) => publish_as.apply(pkg),
            None => (pkg.full_name.clone(), pkg.version.clone()),
        };
        if let Some(tag) = &options.preview {
            pub_version = format!("{pub_version}-{tag}");
        }
        // One broken package must not abort the rest.
        match publish_one(
            pkg,
            &pub_name,
            &pub_version,
            &graphql_url,
            &publish_host,
            &rev,
            &options,
            &packages,
            &batch,
            &mut available,
        ) {
            Ok(true) => published += 1,
            Ok(false) => skipped += 1,
            Err(error) => {
                crate::support::ui::result(format!(
                    "✗ {pub_name}@{pub_version}  {}",
                    crate::support::error::brief(&error, 400)
                ));
                failures.push(pub_name.clone());
            }
        }
    }

    crate::support::ui::result(crate::support::ui::counts(&[
        format!("{published} published"),
        format!("{skipped} skipped"),
        format!("{} failed", failures.len()),
        format!("{} total", ordered.len()),
    ]));
    if !failures.is_empty() {
        crate::support::ui::result(format!("failed: {}", failures.join(", ")));
        return Ok(crate::support::process::CommandStatus::FAILURE);
    }
    Ok(crate::support::process::CommandStatus::SUCCESS)
}

#[allow(clippy::too_many_arguments)]
fn publish_one(
    pkg: &Package,
    pub_name: &str,
    pub_version: &str,
    graphql_url: &str,
    publish_host: &str,
    rev: &str,
    options: &Options,
    packages: &BTreeMap<(String, String), Package>,
    batch: &BTreeSet<(String, String)>,
    available: &mut BTreeSet<(String, String)>,
) -> Result<bool> {
    let existing = get_published(graphql_url, pub_name, pub_version)?;
    if existing.exists {
        available.insert(pkg.key());
        if options.skip_sha_validation || options.preview.is_some() {
            crate::support::ui::result(format!(
                "· {pub_name}@{pub_version}  already exists (hash validation skipped)"
            ));
            return Ok(false);
        }
        let Some(registry_sha) = &existing.webc_sha256 else {
            return package_error(
                "cannot verify the published hash; the registry response did not include a usable SHA-256 hash",
            );
        };
        // The published artifact carries publish-time README lines, so the
        // local build is restaged with the recorded rev to reproduce it.
        // Artifacts published without provenance compare bare.
        let local = match recorded_rev(existing.readme.as_deref()) {
            Some(published_rev) => staged_sha256(pkg, &published_rev, pub_name, pub_version)?,
            None => build_webc_sha256(&pkg.path, pkg)?,
        };
        if &local != registry_sha {
            return package_error(format!(
                "hash mismatch: local={local} registry={registry_sha}; registry versions are immutable and no webc rel encoding exists yet (WASIX-TODO.md), so this version cannot be republished"
            ));
        }
        crate::support::ui::result(format!(
            "· {pub_name}@{pub_version}  already exists (hash match: {local})"
        ));
        return Ok(false);
    }

    // Batch dependencies publish earlier; the rest must already be in the
    // registry or the published webc cannot resolve them. Keyed by
    // (name, version): a dependent needs its exact pin.
    for (dep_name, dep_version) in &pkg.dependencies {
        let dep = (dep_name.clone(), dep_version.clone());
        if available.contains(&dep) {
            continue;
        }
        if packages.contains_key(&dep) {
            return package_error(format!(
                "dependency {dep_name}@{dep_version} failed earlier in this run"
            ));
        }
        if !get_published(graphql_url, dep_name, dep_version)?.exists {
            return package_error(format!(
                "depends on {dep_name}@{dep_version}, which is neither published nor part of this run"
            ));
        }
        available.insert(dep);
    }

    if options.effects.is_dry_run() {
        crate::support::ui::result(format!(
            "✓ {pub_name}@{pub_version}  would publish ({})",
            pkg.path.display()
        ));
        available.insert(pkg.key());
        return Ok(true);
    }

    crate::support::ui::fact("publishing", format!("{pub_name}@{pub_version} at {rev}"));
    let scratch = Scratch::new("publish")?;
    let staged = stage(
        pkg,
        rev,
        &scratch.0,
        pub_name,
        pub_version,
        options.preview.as_deref(),
        batch,
    )?;
    let staged_sha = build_webc_sha256(&staged, pkg)?;
    run(Command::new("wasmer")
        .args(["publish", "--non-interactive", "--registry", publish_host])
        .current_dir(&staged))?;
    drop(scratch);
    verify_published(graphql_url, pub_name, pub_version, &staged_sha)?;
    available.insert(pkg.key());
    Ok(true)
}

/// Merge one file, refusing a same-path entry with different bytes: two
/// sources disagreeing about a webc would silently shadow each other.
fn merge_file(source: &Path, dest: &Path) -> Result<()> {
    if dest.exists() {
        let old = std::fs::read(dest).map_err(|e| crate::support::error::io(dest, e))?;
        let new = std::fs::read(source).map_err(|e| crate::support::error::io(source, e))?;
        if old != new {
            return request_error(format!(
                "{}: conflicting contents from {}",
                dest.display(),
                source.display()
            ));
        }
        return Ok(());
    }
    if let Some(parent) = dest.parent() {
        crate::support::fs::create_dir_all(parent)?;
    }
    std::fs::copy(source, dest).map_err(|e| crate::support::error::io(dest, e))?;
    Ok(())
}

/// Merge a webc tree (or a single .webc file, which lands at the tree root)
/// into the assembled offline tree.
pub fn merge_webcs(from: &Path, into: &Path) -> Result<()> {
    if from.is_file() {
        let name = from
            .file_name()
            .ok_or_else(|| Error::Request(format!("{}: no file name", from.display())))?;
        return merge_file(from, &into.join(name));
    }
    let mut pending = vec![from.to_path_buf()];
    while let Some(dir) = pending.pop() {
        let entries =
            std::fs::read_dir(&dir).map_err(|e| crate::support::error::io(&dir, e))?;
        for entry in entries {
            let path = entry.map_err(|e| crate::support::error::io(&dir, e))?.path();
            if path.is_dir() {
                pending.push(path);
                continue;
            }
            let relative = path.strip_prefix(from).expect("walk stays under from");
            merge_file(&path, &into.join(relative))?;
        }
    }
    Ok(())
}

/// The webcs a tree serves, as owner/name@version references.
fn tree_references(tree: &Path) -> Result<Vec<String>> {
    let mut references = Vec::new();
    let mut pending = vec![tree.to_path_buf()];
    while let Some(dir) = pending.pop() {
        let entries =
            std::fs::read_dir(&dir).map_err(|e| crate::support::error::io(&dir, e))?;
        for entry in entries {
            let path = entry.map_err(|e| crate::support::error::io(&dir, e))?.path();
            if path.is_dir() {
                pending.push(path);
                continue;
            }
            if path.extension().is_none_or(|ext| ext != "webc") {
                continue;
            }
            let relative = path.strip_prefix(tree).expect("walk stays under tree");
            let parts: Vec<_> = relative
                .components()
                .map(|part| part.as_os_str().to_string_lossy().to_string())
                .collect();
            references.push(match parts.as_slice() {
                [owner, name, version] => format!(
                    "{owner}/{name}@{}",
                    version.trim_end_matches(".webc")
                ),
                _ => relative.display().to_string(),
            });
        }
    }
    references.sort();
    Ok(references)
}

pub struct ServeOptions {
    /// Packages, as attr paths or abbreviations; none (and no --webc) means
    /// all shipped.
    pub packages: Vec<String>,
    /// Materialize the tree here; a kept temp directory when absent.
    pub out: Option<PathBuf>,
    /// Prebuilt webc trees or files merged in without any evaluation, which
    /// is how sandboxed checks drive this.
    pub webcs: Vec<PathBuf>,
    pub exec: Vec<String>,
}

/// Materialize the selected packages' webcs and dependency closures as one
/// offline tree, and print how to run against it. This cell yields a path,
/// not a URL: the wasmer CLI has no local-HTTP registry mode, and
/// `--offline --include-webc <tree>` is its native offline consumption.
pub fn serve(options: ServeOptions) -> Result<crate::support::process::CommandStatus> {
    let exec = options.exec.clone();
    let tree = materialize(options)?;
    if !exec.is_empty() {
        return exec_with_tree(&tree, &exec);
    }
    Ok(crate::support::process::CommandStatus::SUCCESS)
}

/// Run a command with WASMER_FLAGS pointing at the offline tree; the one
/// spelling of the --exec contract, shared with the meta serve.
pub fn exec_with_tree(
    tree: &Path,
    exec: &[String],
) -> Result<crate::support::process::CommandStatus> {
    let mut cmd = Command::new(&exec[0]);
    cmd.args(&exec[1..]).env(
        "WASMER_FLAGS",
        format!("--offline --include-webc {}", tree.display()),
    );
    crate::support::tools::log(&cmd);
    let status = crate::support::tools::status(&mut cmd)?;
    Ok(crate::support::process::CommandStatus::from_exit(status))
}

/// Assemble the tree and print the references; the caller decides what runs
/// against it.
pub fn materialize(options: ServeOptions) -> Result<PathBuf> {
    let mut sources = options.webcs.clone();
    let build_all = options.packages.is_empty() && options.webcs.is_empty();
    if !options.packages.is_empty() || build_all {
        // One eval answers both what exists and which packages carry a
        // dependency tree (depTree is null for the leaf packages).
        let apply = crate::support::nix::canonical_webcs_apply("_: p: p.pkg.depTree != null");
        let deps =
            crate::support::nix::eval(&Flake::default(), "wasmerPackages", Some(&apply))?;
        let names: Vec<String> = if build_all {
            deps.as_object()
                .into_iter()
                .flatten()
                .map(|(name, _)| name.clone())
                .collect()
        } else {
            selected_packages(&options.packages)?
        };
        let mut installables: Vec<String> = Vec::new();
        for name in &names {
            let quoted = naming::quoted_attr(name)?;
            installables.push(format!(".#wasmerPackages.{quoted}.webc"));
            if deps[name].as_bool() == Some(true) {
                installables.push(format!(".#wasmerPackages.{quoted}.pkg.depTree"));
            }
        }
        crate::support::ui::fact("building", format!("{} webc closures", names.len()));
        let paths = crate::support::nix::Invocation::flake("build", &installables[0])
            .operands(&installables[1..])
            .arg("--no-link")
            .out_paths("building the webc closures")?;
        sources.extend(paths);
    }
    if sources.is_empty() {
        return request_error("nothing selected to serve");
    }

    let tree = match &options.out {
        Some(dir) => {
            crate::support::fs::create_dir_all(dir)?;
            dir.clone()
        }
        None => {
            let base = crate::support::env::temp_dir().join("wasinix-webc-trees");
            crate::support::fs::create_dir_all(&base)?;
            let dir = base.join(format!(
                "tree-{}-{}",
                std::process::id(),
                crate::support::time::unix_secs()
            ));
            crate::support::fs::create_dir_all(&dir)?;
            dir
        }
    };
    for source in &sources {
        merge_webcs(source, &tree)?;
    }

    let references = tree_references(&tree)?;
    crate::support::ui::result(format!(
        "offline webc tree at {} · {} webcs",
        tree.display(),
        references.len()
    ));
    for reference in &references {
        crate::support::ui::result(format!("  {reference}"));
    }
    crate::support::ui::result(format!(
        "  use:   wasmer run --offline --include-webc {} <owner/pkg[@version]>",
        tree.display()
    ));
    Ok(tree)
}
