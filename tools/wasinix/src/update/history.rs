//! The registry-history tables: older versions we keep rebuildable.
//!
//! Two tables, one shape, one writer. An entry re-points the package's *own*
//! src fetcher at an older version, hashed the way that fetcher hashes, so what
//! the loader builds is what the package would have built at that version.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::LazyLock;

use regex::Regex;
use serde_json::{Value, json};

use crate::support::error::{Result, request_error};
use crate::support::naming::{self, Domain, Resolved};
use crate::support::nix::{Flake, eval};

/// The interpreters the wheel set ships.
const INTERPRETERS: [&str; 2] = ["py313", "py314"];
const WHEEL_ROOT: &str = "packages.python";
const CLI_ROOT: &str = "packages.wasix";
/// A fixed-output derivation is keyed by its hash, so re-pointing a fetcher
/// without also replacing the hash returns the cached old content.
const FAKE_HASH: &str = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";

static NORMALIZE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"[-_.]+").unwrap());
static PLAIN_VERSION: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^\d+(?:\.\d+)*$").unwrap());
static GOT_HASH: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"got:\s*(sha256-\S+)").unwrap());
static REQUIREMENT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^([A-Za-z0-9._-]+)(?:\[[^]]*\])?==(\S+)$").unwrap());
static CP_TAG: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"cp3(\d+)").unwrap());

/// PEP 503 name normalization, so a lockfile pin matches an attr.
pub fn normalize(name: &str) -> String {
    NORMALIZE.replace_all(name, "-").to_lowercase()
}

/// Release-grade versions only: a pre/dev/post release is never a history
/// candidate.
pub fn parse_version(value: &str) -> Option<Vec<u64>> {
    PLAIN_VERSION.is_match(value).then(|| {
        value
            .split('.')
            .filter_map(|part| part.parse().ok())
            .collect()
    })
}

#[derive(Debug, Clone)]
pub struct Target {
    /// The history.json key: a wheel attr, or a CLI's overlay attr.
    pub attr: String,
    /// Flake attr path of the *current* package, which the rebase derives from.
    pub path: String,
    pub history: PathBuf,
    /// Whether PyPI has metadata for it: the release list, sdist hash and
    /// wheel tags all come from there.
    pub pypi: bool,
    /// The set's build-variant axis, or None for a set with a single variant.
    /// For wheels a variant is an interpreter.
    pub variants: Option<Vec<String>>,
}

pub fn wheel_history(repo: &Path) -> PathBuf {
    repo.join("pkgs/python-overlays/history.json")
}

fn cli_history(repo: &Path) -> PathBuf {
    repo.join("pkgs/overlays/history.json")
}

/// wheels.nix is pure data; keyed by normalized attr for lockfile matching.
fn wheel_worklist(repo: &Path) -> Result<BTreeMap<String, String>> {
    let output = crate::support::nix::Invocation::expr(
        "eval",
        format!(
            "import {}",
            repo.join("pkgs/python/wheels/default.nix").display()
        ),
    )
    .json()
    .impure()
    .accepts_flake_config()
    .workdir(repo)
    .probe("a failing worklist read reports its own stderr")?;
    if !output.status.is_success() {
        return request_error(format!(
            "could not read the wheel worklist: {}",
            output.stderr.trim()
        ));
    }
    let entries: Value = serde_json::from_slice(&output.stdout).map_err(|source| {
        crate::support::error::Error::Json {
            path: "<wheel worklist>".into(),
            source,
        }
    })?;
    Ok(entries
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|entry| entry["attr"].as_str())
        .map(|attr| (normalize(attr), attr.to_string()))
        .collect())
}

fn wheel_path(attr: &str) -> Result<String> {
    for interpreter in INTERPRETERS.iter().rev() {
        let attrs = eval(
            &Flake::default(),
            &format!("packages.python.{interpreter}"),
            Some("builtins.attrNames"),
        )?;
        if attrs
            .as_array()
            .into_iter()
            .flatten()
            .any(|value| value.as_str() == Some(attr))
        {
            return Ok(format!(
                "packages.python.{interpreter}.{}",
                crate::support::naming::quoted_attr(attr)?
            ));
        }
    }
    request_error(format!("{attr}: not shipped by any interpreter set"))
}

/// Preferred shipped package names with every accepted alias.
fn cli_map() -> Result<BTreeMap<String, String>> {
    let packages = eval(
        &Flake::default(),
        "packages.preferred",
        Some(
            "builtins.mapAttrs (_: p: { aliases = p.passthru.wasinix.aliases or []; shipped = p.passthru.wasinix.shipped or false; })",
        ),
    )?;
    let mut map = BTreeMap::new();
    for (name, info) in packages.as_object().into_iter().flatten() {
        if !info["shipped"].as_bool().unwrap_or(false) {
            continue;
        }
        map.insert(normalize(name), name.clone());
        for alias in info["aliases"].as_array().into_iter().flatten() {
            if let Some(alias) = alias.as_str() {
                map.insert(normalize(alias), name.clone());
            }
        }
    }
    Ok(map)
}

/// The two sets a name can land in, loaded once so a caller resolving many
/// names evaluates the repo once.
pub struct Sets {
    /// Normalized name -> wheel attr.
    wheels: BTreeMap<String, String>,
    /// Normalized name -> package attr.
    clis: BTreeMap<String, String>,
}

impl Sets {
    /// `only` names the one root the caller can mean, skipping the other's
    /// evaluation.
    pub fn load(repo: &Path, only: Option<&str>) -> Result<Sets> {
        let wants = |root| only.is_none() || only == Some(root);
        Ok(Sets {
            wheels: if wants(WHEEL_ROOT) {
                wheel_worklist(repo)?
            } else {
                BTreeMap::new()
            },
            clis: if wants(CLI_ROOT) {
                cli_map()?
            } else {
                BTreeMap::new()
            },
        })
    }
    /// One entry per interpreter, all keyed by the same attr: a history entry
    /// covers every interpreter, so `packages.python.numpy` is the address and the
    /// interpreter segment is the variant.
    pub fn domain(&self) -> Domain {
        let mut domain = Domain::new("the shipped wheels and CLIs");
        for attr in self.wheels.values() {
            for interpreter in INTERPRETERS {
                let path = vec![
                    "packages".into(),
                    "python".into(),
                    interpreter.into(),
                    attr.clone(),
                ];
                let axis = naming::axis_of(&path);
                domain.add_path(path, attr, axis, vec![normalize(attr)]);
            }
        }
        let clis: BTreeSet<&String> = self.clis.values().collect();
        for name in clis {
            domain.add_path(
                vec!["packages".into(), "wasix".into(), name.clone()],
                name,
                None,
                vec![normalize(name)],
            );
        }
        domain
    }

    fn wheel_target(&self, repo: &Path, name: &str) -> Result<Option<Target>> {
        let Some(attr) = self.wheels.get(&normalize(name)) else {
            return Ok(None);
        };
        Ok(Some(Target {
            path: wheel_path(attr)?,
            attr: attr.clone(),
            history: wheel_history(repo),
            pypi: true,
            variants: Some(INTERPRETERS.iter().map(|i| i.to_string()).collect()),
        }))
    }

    /// The domain is built from these same maps, so a name it resolved is
    /// always in them.
    fn target(&self, repo: &Path, resolved: &Resolved) -> Result<Target> {
        let missing = || format!("{} is not in the loaded set", resolved.address());
        if resolved
            .path
            .starts_with(&["packages".to_string(), "python".to_string()])
        {
            return self
                .wheel_target(repo, &resolved.key)?
                .ok_or_else(|| crate::support::error::Error::Request(missing()));
        }
        let Some(attr) = self.clis.get(&normalize(&resolved.key)) else {
            return request_error(missing());
        };
        Ok(Target {
            attr: attr.clone(),
            path: format!(
                "packages.preferred.{}",
                crate::support::naming::quoted_attr(attr)?
            ),
            history: cli_history(repo),
            pypi: false,
            variants: None,
        })
    }
}

/// The root a spec names, when it names one. Loading the other set is an
/// evaluation, so it is worth knowing before it happens.
fn named_root(segments: &[String]) -> Option<&str> {
    match segments {
        [root, lane, ..] if root == "packages" && lane == "python" => Some(WHEEL_ROOT),
        [root, lane, ..] if root == "packages" && lane == "wasix" => Some(CLI_ROOT),
        _ => None,
    }
}

/// The one package a spec names, and the version it asked for.
pub fn resolve(repo: &Path, spec: &str) -> Result<(Target, Option<String>)> {
    let mut spec = naming::parse(spec)?;
    let sets = Sets::load(repo, named_root(&spec.segments))?;
    // PEP 503 folds `Foo_Bar` and `foo-bar` onto one name. A glob is left as
    // typed, so its wildcards keep meaning what they say.
    if !spec.is_glob() {
        if let Some(leaf) = spec.segments.last_mut() {
            *leaf = normalize(leaf);
        }
    }
    let hits = sets.domain().resolve(&spec)?;
    if hits.len() > 1 {
        let names: Vec<String> = hits.iter().map(Resolved::address).collect();
        return request_error(format!(
            "{}: history takes one package, this names {}",
            spec.render(),
            names.join(", ")
        ));
    }
    Ok((sets.target(repo, &hits[0])?, hits[0].value.clone()))
}

/// The current package's src fetcher fields, so an entry can re-point the same
/// fetcher rather than inventing one.
#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Coords {
    pub version: String,
    pub pname: Option<String>,
    pub has_src: bool,
    pub tag: Option<String>,
    pub rev: Option<String>,
    pub url: Option<String>,
    pub owner: Option<String>,
    pub repo: Option<String>,
    pub has_override: bool,
    pub cargo_deps: bool,
}

pub fn src_coords(target: &Target) -> Result<Coords> {
    crate::support::json::from_value(
        eval(
            &Flake::default(),
            &target.path,
            Some(
                "p: let s = p.src or {}; in { version = p.version; \
                 pname = p.pname or null; hasSrc = p ? src; tag = s.tag or null; \
                 rev = s.rev or null; url = s.url or null; owner = s.owner or null; \
                 repo = s.repo or null; hasOverride = s ? override; \
                 cargoDeps = p ? cargoDeps; }",
            ),
        )?,
        &target.path,
    )
}

fn pypi(url: &str) -> Result<Value> {
    crate::support::http::get_json(url)
}

fn github_tags(owner: &str, repo: &str) -> Result<Vec<String>> {
    let mut tags = Vec::new();
    // 1000 tags is plenty to cover every major.
    for page in 1..=10 {
        let path = format!("repos/{owner}/{repo}/tags?per_page=100&page={page}");
        let data = crate::github::client::Client::new(crate::github::client::token().as_deref())
            .get(&path)?;
        let Some(items) = data.as_array() else { break };
        tags.extend(
            items
                .iter()
                .filter_map(|tag| tag["name"].as_str().map(str::to_string)),
        );
        if items.len() < 100 {
            break;
        }
    }
    Ok(tags)
}

/// Upstream versions for bulk mode, from whatever index the source has.
pub fn list_versions(target: &Target, project: &str, coords: &Coords) -> Result<Vec<String>> {
    if target.pypi {
        let data = pypi(&format!("https://pypi.org/pypi/{project}/json"))?;
        return Ok(data["releases"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(version, _)| version.clone())
            .collect());
    }
    if let (Some(owner), Some(repo)) = (&coords.owner, &coords.repo) {
        // The constant part of the current tag around its version ("v2.5.0" ->
        // "v"), used to read a version out of each tag.
        let field = coords
            .tag
            .clone()
            .or_else(|| coords.rev.clone())
            .unwrap_or_default();
        let prefix = match field.find(&coords.version) {
            Some(index) => field[..index].to_string(),
            None => String::new(),
        };
        return Ok(github_tags(owner, repo)?
            .into_iter()
            .filter(|tag| prefix.is_empty() || tag.starts_with(&prefix))
            .map(|tag| tag[prefix.len()..].to_string())
            .filter(|version| parse_version(version).is_some())
            .collect());
    }
    request_error(format!(
        "{}: --per-major/--per-minor need a version index; its source is a bare fetchurl (no tag list), so add versions explicitly",
        target.attr
    ))
}

fn nix_attrs(spec: &BTreeMap<String, String>) -> String {
    let body: Vec<String> = spec
        .iter()
        .map(|(key, value)| format!("{key} = \"{value}\";"))
        .collect();
    format!("{{ {} }}", body.join(" "))
}

fn build_for_hash(repo: &Path, expr: &str) -> Result<crate::support::nix::Probe> {
    crate::support::nix::Invocation::expr("build", expr)
        .impure()
        .arg("--no-link")
        .accepts_flake_config()
        .workdir(repo)
        .probe("the wanted hash is mined from the failing build's stderr")
}

fn hash_from_output(output: &crate::support::nix::Probe, context: &str) -> Result<String> {
    let stderr = &output.stderr;
    match GOT_HASH.captures(stderr) {
        Some(captured) => Ok(captured[1].to_string()),
        None => request_error(format!(
            "{context}: {}",
            crate::support::error::tail(stderr, 400)
        )),
    }
}

/// Build the current src re-pointed at the older version with a fake hash; the
/// fixed-output mismatch reports the real one.
fn tofu_hash(repo: &Path, target: &Target, mut args: BTreeMap<String, String>) -> Result<String> {
    args.insert("hash".into(), FAKE_HASH.into());
    let expression = |args: &BTreeMap<String, String>| {
        format!(
            "(builtins.getFlake \"{}\").{}.{}.src.override ({})",
            repo.display(),
            crate::support::nix::project_attr(""),
            target.path,
            nix_attrs(args)
        )
    };
    let mut output = build_for_hash(repo, &expression(&args))?;
    if output.stderr.contains("multiple hashes passed") {
        args.remove("hash");
        args.insert("sha256".into(), FAKE_HASH.into());
        output = build_for_hash(repo, &expression(&args))?;
    }
    hash_from_output(&output, &format!("could not TOFU hash for {}", target.attr))
}

/// A rust wheel vendors its crates from the Cargo.lock inside its own source,
/// so an older src needs its own vendor and nothing else derives that hash.
fn tofu_cargo_hash(
    repo: &Path,
    target: &Target,
    src_args: &BTreeMap<String, String>,
) -> Result<Option<String>> {
    let expr = format!(
        "let p = (builtins.getFlake \"{}\").{}.{}; \
         newSrc = p.src.override ({}); in \
         if p.cargoDeps ? wasixRebuildVendor \
         then p.cargoDeps.wasixRebuildVendor {{ src = newSrc; cargoHash = \"{FAKE_HASH}\"; }} \
         else p.cargoDeps.overrideAttrs (o: {{ vendorStaging = o.vendorStaging.overrideAttrs \
         (_: {{ src = newSrc; outputHash = \"{FAKE_HASH}\"; }}); }})",
        repo.display(),
        crate::support::nix::project_attr(""),
        target.path,
        nix_attrs(src_args)
    );
    let output = build_for_hash(repo, &expr)?;
    if let Some(captured) = GOT_HASH.captures(&output.stderr) {
        return Ok(Some(captured[1].to_string()));
    }
    if output.status.is_success() {
        return Ok(None);
    }
    hash_from_output(
        &output,
        "could not vendor rust deps for this version (the lock may have moved, which the package file has to correct)",
    )
    .map(Some)
}

/// Re-point one fetcher field from the current version to an older one. A
/// no-op substitution means the current version is not spelled in the field,
/// which would silently pin the current source under an older version's key.
pub fn substitute_version(
    field: &str,
    value: &str,
    current: &str,
    version: &str,
) -> Result<String> {
    // Digit-bounded matches only: a bare "2" must not rewrite part of a port
    // or a date in the middle of a url, while "v2.5.0" stays a version. Every
    // occurrence is replaced, including two that share a boundary character
    // (`.../1.2.3/1.2.3.tar.gz`), which a boundary-consuming regex would miss.
    let bounded = |haystack: &str, needle: &str, replacement: &str| -> String {
        if needle.is_empty() {
            return haystack.to_string();
        }
        let digit = |byte: Option<u8>| byte.is_some_and(|b| b.is_ascii_digit());
        let bytes = haystack.as_bytes();
        let mut out = String::with_capacity(haystack.len());
        let mut index = 0;
        while index < haystack.len() {
            if haystack[index..].starts_with(needle) {
                let before = (index > 0).then(|| bytes[index - 1]);
                let after = bytes.get(index + needle.len()).copied();
                if !digit(before) && !digit(after) {
                    out.push_str(replacement);
                    index += needle.len();
                    continue;
                }
            }
            let ch = haystack[index..]
                .chars()
                .next()
                .expect("index is on a boundary");
            out.push(ch);
            index += ch.len_utf8();
        }
        out
    };
    let mut out = bounded(value, current, version);
    if out == value {
        for separator in ['_', '-'] {
            let respelled = current.replace('.', &separator.to_string());
            if value.contains(&respelled) {
                out = bounded(
                    value,
                    &respelled,
                    &version.replace('.', &separator.to_string()),
                );
                break;
            }
        }
    }
    if out == value {
        return request_error(format!(
            "cannot re-point src.{field} \"{value}\" from {current} to {version}: the current version does not appear in it, so the older release has to be added by hand"
        ));
    }
    Ok(out)
}

/// PyPI reports an sdist digest in hex; an SRI hash wants it base64.
pub fn base64_of_hex(hex: &str) -> Option<String> {
    use base64::Engine;
    hex_to_bytes(hex).map(|bytes| base64::engine::general_purpose::STANDARD.encode(bytes))
}

fn hex_to_bytes(hex: &str) -> Option<Vec<u8>> {
    hex.len()
        .is_multiple_of(2)
        .then(|| {
            (0..hex.len())
                .step_by(2)
                .map(|index| u8::from_str_radix(&hex[index..index + 2], 16).ok())
                .collect::<Option<Vec<u8>>>()
        })
        .flatten()
}

fn hash_field(repo: &Path, target: &Target) -> Result<&'static str> {
    let expr = format!(
        "(builtins.getFlake \"{}\").{}.{}.src.override \
         {{ hash = \"{FAKE_HASH}\"; }}",
        repo.display(),
        crate::support::nix::project_attr(""),
        target.path
    );
    let output = crate::support::nix::Invocation::expr("eval", &expr)
        .impure()
        .apply("d: d.outputHash")
        .workdir(repo)
        .probe("the field name is judged from the eval's own complaint")?;
    Ok(if output.stderr.contains("multiple hashes passed") {
        "sha256"
    } else {
        "hash"
    })
}

fn concrete_url(repo: &Path, url: &str) -> Result<String> {
    let Some(path) = url.strip_prefix("mirror://") else {
        return Ok(url.to_string());
    };
    let Some((name, suffix)) = path.split_once('/') else {
        return request_error(format!("invalid mirror url: {url}"));
    };
    let expr = format!(
        "builtins.getAttr {} (import ((builtins.getFlake \"{}\").inputs.nixpkgs \
         + \"/pkgs/build-support/fetchurl/mirrors.nix\"))",
        serde_json::Value::String(name.to_string()),
        repo.display()
    );
    let output = crate::support::nix::Invocation::expr("eval", &expr)
        .json()
        .impure()
        .workdir(repo)
        .probe("a failed mirror resolve names the url")?;
    if !output.status.is_success() {
        return request_error(format!("could not resolve {url}: {}", output.stderr.trim()));
    }
    let mirrors: Vec<String> = serde_json::from_slice(&output.stdout).map_err(|source| {
        crate::support::error::Error::Json {
            path: "<nixpkgs mirrors>".into(),
            source,
        }
    })?;
    let Some(base) = mirrors.first() else {
        return request_error(format!("mirror {name} has no urls"));
    };
    Ok(format!("{}/{suffix}", base.trim_end_matches('/')))
}

fn src_spec(
    repo: &Path,
    target: &Target,
    version: &str,
    coords: &Coords,
    files: Option<&Value>,
) -> Result<BTreeMap<String, String>> {
    let current = &coords.version;
    for (field, value) in [("tag", &coords.tag), ("rev", &coords.rev)] {
        if let Some(value) = value {
            let mut args = BTreeMap::new();
            args.insert(
                field.to_string(),
                substitute_version(field, value, current, version)?,
            );
            let hash = tofu_hash(repo, target, args.clone())?;
            args.insert("hash".into(), hash);
            return Ok(args);
        }
    }
    if coords.has_override {
        // fetchPypi: the version selects the url, and the hash is the sdist's.
        let sdist = files
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .find(|file| file["packagetype"].as_str() == Some("sdist"));
        let Some(sdist) = sdist else {
            return request_error(format!(
                "no sdist on PyPI for {version}; cannot build from source"
            ));
        };
        let Some(digest) = sdist["digests"]["sha256"].as_str() else {
            return request_error(format!("sdist for {version} has no sha256 digest"));
        };
        let Some(encoded) = base64_of_hex(digest) else {
            return request_error(format!("malformed sdist digest for {version}"));
        };
        let mut spec = BTreeMap::new();
        spec.insert("version".into(), version.to_string());
        spec.insert(
            hash_field(repo, target)?.into(),
            format!("sha256-{encoded}"),
        );
        let mut stem = sdist["filename"].as_str().unwrap_or_default();
        for extension in [".tar.gz", ".zip", ".tar.bz2"] {
            if let Some(without) = stem.strip_suffix(extension) {
                stem = without;
                break;
            }
        }
        let released_as = stem.rsplit_once('-').map(|(name, _)| name).unwrap_or(stem);
        if coords
            .pname
            .as_deref()
            .is_some_and(|name| name != released_as)
        {
            spec.insert("pname".into(), released_as.to_string());
        }
        return Ok(spec);
    }
    if !coords.has_src {
        return request_error(format!(
            "{}: cannot determine how to re-point its fetcher",
            target.attr
        ));
    }
    let Some(url) = &coords.url else {
        return request_error(format!(
            "{}: cannot determine how to re-point its fetcher",
            target.attr
        ));
    };
    let url = substitute_version("url", url, current, version)?;
    let output = crate::support::nix::Invocation::plain("store prefetch-file")
        .json()
        .operand(concrete_url(repo, &url)?)
        .workdir(repo)
        .probe("a failed prefetch names the url")?;
    if !output.status.is_success() {
        return request_error(format!(
            "prefetch of {url} failed: {}",
            output.stderr.trim()
        ));
    }
    let prefetched: Value = serde_json::from_slice(&output.stdout).map_err(|source| {
        crate::support::error::Error::Json {
            path: "<nix store prefetch-file>".into(),
            source,
        }
    })?;
    let mut spec = BTreeMap::new();
    spec.insert("url".into(), url);
    spec.insert(
        "hash".into(),
        prefetched["hash"].as_str().unwrap_or_default().to_string(),
    );
    Ok(spec)
}

pub fn fetch_spec(
    repo: &Path,
    target: &Target,
    version: &str,
    coords: &Coords,
    files: Option<&Value>,
) -> Result<BTreeMap<String, String>> {
    let mut spec = src_spec(repo, target, version, coords, files)?;
    if coords.cargo_deps {
        let src_args: BTreeMap<String, String> = spec
            .iter()
            .filter(|(key, _)| *key != "cargoHash")
            .map(|(key, value)| (key.clone(), value.clone()))
            .collect();
        if let Some(hash) = tofu_cargo_hash(repo, target, &src_args)? {
            spec.insert("cargoHash".into(), hash);
        }
    }
    Ok(spec)
}

/// Interpreters a release supports, read from its upstream wheel tags. `None`
/// means it published no wheels at all, which the caller decides about.
pub fn supported_pythons(files: &Value) -> Option<BTreeSet<String>> {
    let mut supported = BTreeSet::new();
    let mut saw_wheel = false;
    let mut saw_native = false;
    for file in files.as_array().into_iter().flatten() {
        let Some(name) = file["filename"].as_str() else {
            continue;
        };
        let Some(stem) = name.strip_suffix(".whl") else {
            continue;
        };
        saw_wheel = true;
        let parts: Vec<&str> = stem.rsplitn(4, '-').collect();
        if parts.len() < 4 {
            continue;
        }
        // A wheel is {name}-{version}-{python}-{abi}-{platform}.whl, and
        // rsplitn yields reversed: platform, abi, python, then the rest.
        let (python, abi, platform) = (parts[2], parts[1], parts[0]);
        if platform == "any" && abi == "none" && python.contains("py3") {
            continue;
        }
        saw_native = true;
        if abi == "abi3" {
            if let Some(captured) = CP_TAG.captures(python) {
                // The stable ABI is forward-compatible from its floor.
                if let Ok(floor) = captured[1].parse::<u32>() {
                    for interpreter in INTERPRETERS {
                        if interpreter[3..].parse::<u32>().is_ok_and(|v| v >= floor) {
                            supported.insert(interpreter.to_string());
                        }
                    }
                }
            }
        }
        for interpreter in INTERPRETERS {
            if python.contains(&format!("cp3{}", &interpreter[3..])) {
                supported.insert(interpreter.to_string());
            }
        }
    }
    if !saw_wheel {
        None
    } else if !saw_native {
        Some(INTERPRETERS.iter().map(|i| i.to_string()).collect())
    } else {
        Some(supported)
    }
}

pub type History = BTreeMap<String, BTreeMap<String, Value>>;

pub fn load_history(path: &Path) -> Result<History> {
    crate::support::json::read(path)
}

pub fn write_history(repo: &Path, path: &Path, history: &History, dry_run: bool) -> Result<()> {
    if dry_run {
        let shown = path.strip_prefix(repo).unwrap_or(path);
        crate::support::ui::result(format!("--dry-run; would write {}:", shown.display()));
        let mut text = serde_json::to_string_pretty(history).map_err(|source| {
            crate::support::error::Error::Json {
                path: path.to_path_buf(),
                source,
            }
        })?;
        text.push('\n');
        crate::support::ui::output(text);
        return Ok(());
    }
    crate::support::json::write(path, history)
}

/// An entry is minted by rebasing the current package's src, which only reaches
/// a package deriving from that set. One that spells its own version ignores
/// the rebase, and the loader throws rather than serve the current version
/// under an older name. Force that throw to land here and take the entries back
/// out: automation must not leave a table nothing can evaluate.
pub fn verify_mint(repo: &Path, target: &Target, added: &[String], before: &History) -> Result<()> {
    if added.is_empty() {
        return Ok(());
    }
    let output = crate::support::nix::Invocation::flake(
        "eval",
        format!(".#{}", crate::support::nix::project_attr("schemaVersion")),
    )
    .workdir(repo)
    .probe("verify_mint reports the failing set's own stderr")?;
    if !output.status.is_success() {
        write_history(repo, &target.history, before, false)?;
        let tail = crate::support::error::tail(&output.stderr, 600);
        return request_error(format!(
            "{}: reverted {}, the set no longer evaluates:\n{tail}",
            target.attr,
            added.join(", ")
        ));
    }
    Ok(())
}

/// What one version's add actually did; "skipped" must never read as
/// "retained" to a caller that needed the entry.
#[derive(Debug, Clone, PartialEq)]
pub enum AddOutcome {
    Added { detail: String },
    AlreadyPresent,
    CurrentVersion,
    Skipped { reason: String },
}

pub struct AddOptions {
    pub variants: Option<Vec<String>>,
    pub note: Option<String>,
    pub force: bool,
    pub skip_unsupported: bool,
}

pub fn add_version(
    repo: &Path,
    target: &Target,
    history: &mut History,
    project: &str,
    version: &str,
    options: &AddOptions,
) -> Result<AddOutcome> {
    if history
        .get(&target.attr)
        .is_some_and(|versions| versions.contains_key(version))
    {
        return Ok(AddOutcome::AlreadyPresent);
    }
    let coords = src_coords(target)?;
    if version == coords.version {
        return Ok(AddOutcome::CurrentVersion);
    }

    let files = if target.pypi {
        Some(pypi(&format!("https://pypi.org/pypi/{project}/{version}/json"))?["urls"].clone())
    } else {
        None
    };
    let spec = match fetch_spec(repo, target, version, &coords, files.as_ref()) {
        Ok(spec) => spec,
        Err(error) if options.skip_unsupported => {
            return Ok(AddOutcome::Skipped {
                reason: error.to_string(),
            });
        }
        Err(error) => return Err(error),
    };

    // The set-neutral history gate: which of the set's build variants this
    // entry is limited to. A set with a single variant skips it.
    let mut chosen: Option<BTreeSet<String>> = None;
    if let Some(all) = &target.variants {
        let all: BTreeSet<String> = all.iter().cloned().collect();
        let picked = match (&options.variants, target.pypi) {
            (Some(variants), _) => variants.iter().cloned().collect(),
            (None, true) => match files.as_ref().and_then(supported_pythons) {
                None => {
                    crate::support::ui::warning(format!(
                        "{}@{version}: no upstream wheels to judge support; assuming all",
                        target.attr
                    ));
                    all.clone()
                }
                Some(supported) if supported.is_empty() => {
                    // Upstream shipped wheels but none for our interpreters. The
                    // sdist may still compile, but an old C API usually will
                    // not, so make it an explicit call.
                    let message = format!(
                        "{}@{version}: no upstream cp313/cp314 wheels (unsupported interpreters)",
                        target.attr
                    );
                    if options.force {
                        all.clone()
                    } else if options.skip_unsupported {
                        return Ok(AddOutcome::Skipped {
                            reason: "no upstream cp313/cp314 wheels (unsupported interpreters)"
                                .to_string(),
                        });
                    } else {
                        return request_error(format!(
                            "{message}; --force to add anyway, --variants to narrow"
                        ));
                    }
                }
                Some(supported) => supported,
            },
            (None, false) => all.clone(),
        };
        chosen = Some(picked);
    }

    // The fetcher fields are strings; variants and the note are the entry's
    // own keys, so the spec stays exactly what re-points the fetcher.
    let mut entry: BTreeMap<String, Value> = spec
        .into_iter()
        .map(|(key, value)| (key, Value::String(value)))
        .collect();
    if let (Some(picked), Some(all)) = (&chosen, &target.variants) {
        let all: BTreeSet<String> = all.iter().cloned().collect();
        // Only a narrowed set is recorded: covering every variant is the default.
        if picked != &all {
            entry.insert(
                "variants".into(),
                json!(picked.iter().cloned().collect::<Vec<_>>()),
            );
        }
    }
    if let Some(note) = &options.note {
        entry.insert("note".into(), Value::String(note.clone()));
    }
    history.entry(target.attr.clone()).or_default().insert(
        version.to_string(),
        serde_json::to_value(entry).map_err(|source| crate::support::error::Error::Json {
            path: "<history entry>".into(),
            source,
        })?,
    );

    let tail = match &chosen {
        Some(picked) if !picked.is_empty() => {
            format!(
                " ({})",
                picked.iter().cloned().collect::<Vec<_>>().join(", ")
            )
        }
        _ => String::new(),
    };
    Ok(AddOutcome::Added { detail: tail })
}

/// Pins a lockfile declares, for `from-lockfile`.
pub fn lockfile_pins(path: &Path) -> Result<Vec<(String, String)>> {
    let text = crate::support::fs::read_to_string(path)?;
    if path.extension().is_some_and(|ext| ext == "txt") {
        return Ok(text
            .lines()
            .map(|line| {
                line.split('#')
                    .next()
                    .unwrap_or_default()
                    .split(';')
                    .next()
                    .unwrap_or_default()
                    .trim()
                    .to_string()
            })
            .filter_map(|line| {
                REQUIREMENT
                    .captures(&line)
                    .map(|captured| (captured[1].to_string(), captured[2].to_string()))
            })
            .collect());
    }
    let data: toml::Value = toml::from_str(&text).map_err(|error| {
        crate::support::error::Error::Request(format!("{}: {error}", path.display()))
    })?;
    let packages = data
        .get("package")
        .or_else(|| data.get("packages"))
        .and_then(toml::Value::as_array)
        .cloned()
        .unwrap_or_default();
    Ok(packages
        .into_iter()
        .filter_map(|package| {
            let name = package.get("name")?.as_str()?.to_string();
            let version = package.get("version")?.as_str()?.to_string();
            Some((name, version))
        })
        .collect())
}

pub struct AddCommand {
    /// `name[@version]`, optionally address-prefixed
    /// (`packages.python.<name>` / `packages.wasix.<name>`).
    pub spec: String,
    pub per_major: bool,
    pub per_minor: bool,
    pub since: Option<String>,
    pub project: Option<String>,
    pub dry_run: bool,
    pub options: AddOptions,
}

/// Latest release per major or minor series, older than what we ship.
fn bulk_versions(
    target: &Target,
    project: &str,
    coords: &Coords,
    per_major: bool,
    since: Option<&str>,
) -> Result<Vec<String>> {
    // Bulk mode orders candidates against the current version, so an
    // unparseable one would compare as older than everything and select
    // nothing.
    let Some(current) = parse_version(&coords.version) else {
        return request_error(format!(
            "{}: current version \"{}\" is not a plain release, so --per-major/--per-minor cannot order against it; add versions explicitly",
            target.attr, coords.version
        ));
    };
    let floor = since.and_then(parse_version).unwrap_or_default();
    let width = if per_major { 1 } else { 2 };
    let mut groups: BTreeMap<Vec<u64>, (Vec<u64>, String)> = BTreeMap::new();
    for version in list_versions(target, project, coords)? {
        let Some(parsed) = parse_version(&version) else {
            continue;
        };
        // Only versions older than what we ship; newer is the updater's job.
        if parsed < floor || parsed >= current {
            continue;
        }
        let key: Vec<u64> = parsed.iter().take(width).cloned().collect();
        match groups.get(&key) {
            Some((best, _)) if *best >= parsed => {}
            _ => {
                groups.insert(key, (parsed, version));
            }
        }
    }
    let mut ordered: Vec<(Vec<u64>, String)> = groups.into_values().collect();
    ordered.sort();
    Ok(ordered.into_iter().map(|(_, version)| version).collect())
}

/// What a backfill run did, and which history tables it rewrote.
pub struct Backfill {
    pub outcomes: Vec<(String, String, AddOutcome)>,
    /// Tables holding new entries; empty on dry runs and no-ops.
    pub files: Vec<PathBuf>,
}

pub fn add(repo: &Path, command: AddCommand) -> Result<Backfill> {
    let (target, picked) = resolve(repo, &command.spec)?;
    let mut history = load_history(&target.history)?;
    let project = command
        .project
        .clone()
        .unwrap_or_else(|| target.attr.clone());
    let mut options = command.options;

    let versions = match picked {
        Some(version) => vec![version],
        None if command.per_major || command.per_minor => {
            // Bulk mode reports unsupported candidates instead of aborting on
            // the first one.
            options.skip_unsupported = !options.force;
            let coords = src_coords(&target)?;
            let found = bulk_versions(
                &target,
                &project,
                &coords,
                command.per_major,
                command.since.as_deref(),
            )?;
            if found.is_empty() {
                return Ok(Backfill {
                    outcomes: Vec::new(),
                    files: Vec::new(),
                });
            }
            found
        }
        None => return request_error("give @<version>, --per-major, or --per-minor"),
    };

    let before = history.clone();
    let mut outcomes = Vec::new();
    for version in &versions {
        let outcome = add_version(repo, &target, &mut history, &project, version, &options)?;
        outcomes.push((target.attr.clone(), version.clone(), outcome));
    }
    write_history(repo, &target.history, &history, command.dry_run)?;
    if !command.dry_run {
        let added: Vec<String> = history
            .get(&target.attr)
            .into_iter()
            .flatten()
            .map(|(version, _)| version.clone())
            .filter(|version| {
                !before
                    .get(&target.attr)
                    .is_some_and(|old| old.contains_key(version))
            })
            .collect();
        verify_mint(repo, &target, &added, &before)?;
    }
    let added_any = outcomes
        .iter()
        .any(|(_, _, outcome)| matches!(outcome, AddOutcome::Added { .. }));
    let files = if !command.dry_run && added_any {
        vec![target.history.clone()]
    } else {
        Vec::new()
    };
    Ok(Backfill { outcomes, files })
}

pub fn from_lockfile(repo: &Path, path: &Path, dry_run: bool) -> Result<Backfill> {
    let options = AddOptions {
        variants: None,
        note: Some(format!(
            "pinned by {}",
            path.file_name().unwrap_or_default().to_string_lossy()
        )),
        force: false,
        // A foreign lockfile must not hard-fail the run.
        skip_unsupported: true,
    };
    let mut tables: BTreeMap<PathBuf, History> = BTreeMap::new();
    let mut before: BTreeMap<PathBuf, History> = BTreeMap::new();
    let mut touched: Vec<(Target, String)> = Vec::new();
    let mut outcomes = Vec::new();
    // Lockfile pins are python dependencies.
    let sets = Sets::load(repo, Some(WHEEL_ROOT))?;
    for (name, version) in lockfile_pins(path)? {
        let Some(target) = sets.wheel_target(repo, &name)? else {
            continue; // not shipped by us: PyPI serves it
        };
        let history = match tables.get_mut(&target.history) {
            Some(history) => history,
            None => {
                let loaded = load_history(&target.history)?;
                before.insert(target.history.clone(), loaded.clone());
                tables.entry(target.history.clone()).or_insert(loaded)
            }
        };
        // The lockfile name is the PyPI project, which may differ from the attr.
        let outcome = add_version(repo, &target, history, &name, &version, &options)?;
        outcomes.push((target.attr.clone(), version.clone(), outcome.clone()));
        if matches!(outcome, AddOutcome::Added { .. }) {
            touched.push((target, version));
        }
    }
    for (path, history) in &tables {
        write_history(repo, path, history, dry_run)?;
    }
    let mut files: Vec<PathBuf> = if dry_run {
        Vec::new()
    } else {
        touched
            .iter()
            .map(|(target, _)| target.history.clone())
            .collect()
    };
    files.sort();
    files.dedup();
    // Imported entries mint like any other: a table that stops evaluating is
    // reverted here, never left for the next eval to trip on. Verified once
    // per shared table with all of its additions, so one bad entry does not
    // silently revert the good ones from the same file.
    if !dry_run {
        let mut by_table: BTreeMap<PathBuf, (Target, Vec<String>)> = BTreeMap::new();
        for (target, version) in touched {
            by_table
                .entry(target.history.clone())
                .or_insert_with(|| (target, Vec::new()))
                .1
                .push(version);
        }
        for (history_path, (target, versions)) in by_table {
            verify_mint(repo, &target, &versions, &before[&history_path])?;
        }
    }
    Ok(Backfill { outcomes, files })
}
