use std::collections::{BTreeMap, BTreeSet};
use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::Duration;

use flate2::read::GzDecoder;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("{path}: invalid TOML: {source}")]
    Toml {
        path: PathBuf,
        #[source]
        source: toml::de::Error,
    },
    #[error("{path}: invalid JSON: {source}")]
    Json {
        path: PathBuf,
        #[source]
        source: serde_json::Error,
    },
    #[error("{0}")]
    Manifest(String),
    #[error("{name} {version} rejected: {status} {detail}")]
    Rejected {
        name: String,
        version: String,
        status: u16,
        detail: String,
    },
    #[error("publishing {name} {version}: {source}")]
    Transport {
        name: String,
        version: String,
        #[source]
        source: Box<ureq::Transport>,
    },
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct PublishDependency {
    pub name: String,
    pub version_req: String,
    pub features: Vec<String>,
    pub optional: bool,
    pub default_features: bool,
    pub target: Option<String>,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub explicit_name_in_toml: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub registry: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PublishMetadata {
    pub name: String,
    pub vers: String,
    pub deps: Vec<PublishDependency>,
    pub features: toml::Value,
    pub links: Option<String>,
    pub rust_version: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct IndexDependency {
    pub name: String,
    pub req: String,
    pub features: Vec<String>,
    pub optional: bool,
    pub default_features: bool,
    pub target: Option<String>,
    pub kind: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub registry: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub package: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct IndexEntry {
    pub name: String,
    pub vers: String,
    pub deps: Vec<IndexDependency>,
    pub cksum: String,
    pub features: toml::Value,
    pub yanked: bool,
    pub links: Option<String>,
}

fn io(path: impl Into<PathBuf>, source: std::io::Error) -> Error {
    Error::Io {
        path: path.into(),
        source,
    }
}

fn table<'a>(
    value: &'a toml::Value,
    field: &str,
) -> Result<&'a toml::map::Map<String, toml::Value>> {
    value
        .get(field)
        .and_then(toml::Value::as_table)
        .ok_or_else(|| Error::Manifest(format!("Cargo.toml has no [{field}] table")))
}

fn string_field(table: &toml::map::Map<String, toml::Value>, field: &str) -> Result<String> {
    table
        .get(field)
        .and_then(toml::Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| Error::Manifest(format!("Cargo.toml [package] has no string {field}")))
}

fn dependency(
    key: &str,
    value: &toml::Value,
    kind: &str,
    target: Option<&str>,
) -> Result<PublishDependency> {
    let mut spec = toml::map::Map::new();
    if let Some(version) = value.as_str() {
        spec.insert("version".into(), toml::Value::String(version.into()));
    } else if let Some(value) = value.as_table() {
        spec = value.clone();
    } else {
        return Err(Error::Manifest(format!(
            "dependency {key} must be a version string or table"
        )));
    }
    let package = spec.get("package").and_then(toml::Value::as_str);
    let features = spec
        .get("features")
        .and_then(toml::Value::as_array)
        .map(|values| {
            values
                .iter()
                .map(|value| {
                    value.as_str().map(str::to_owned).ok_or_else(|| {
                        Error::Manifest(format!("dependency {key} has a non-string feature"))
                    })
                })
                .collect()
        })
        .transpose()?
        .unwrap_or_default();
    Ok(PublishDependency {
        name: package.unwrap_or(key).to_owned(),
        version_req: spec
            .get("version")
            .and_then(toml::Value::as_str)
            .unwrap_or("*")
            .to_owned(),
        features,
        optional: spec
            .get("optional")
            .and_then(toml::Value::as_bool)
            .unwrap_or(false),
        default_features: spec
            .get("default-features")
            .and_then(toml::Value::as_bool)
            .unwrap_or(true),
        target: target.map(str::to_owned),
        kind: kind.to_owned(),
        explicit_name_in_toml: package.map(|_| key.to_owned()),
        registry: spec
            .get("registry")
            .and_then(toml::Value::as_str)
            .map(str::to_owned),
    })
}

fn append_dependencies(
    output: &mut Vec<PublishDependency>,
    owner: &toml::map::Map<String, toml::Value>,
    target: Option<&str>,
) -> Result<()> {
    for (table_name, kind) in [
        ("dependencies", "normal"),
        ("dev-dependencies", "dev"),
        ("build-dependencies", "build"),
    ] {
        let Some(dependencies) = owner.get(table_name) else {
            continue;
        };
        let dependencies = dependencies
            .as_table()
            .ok_or_else(|| Error::Manifest(format!("Cargo.toml [{table_name}] is not a table")))?;
        for (name, value) in dependencies {
            output.push(dependency(name, value, kind, target)?);
        }
    }
    Ok(())
}

pub fn metadata_from_manifest(manifest: &toml::Value) -> Result<PublishMetadata> {
    let root = manifest
        .as_table()
        .ok_or_else(|| Error::Manifest("Cargo.toml root is not a table".into()))?;
    let package = table(manifest, "package")?;
    let mut deps = Vec::new();
    append_dependencies(&mut deps, root, None)?;
    if let Some(targets) = root.get("target") {
        let targets = targets
            .as_table()
            .ok_or_else(|| Error::Manifest("Cargo.toml [target] is not a table".into()))?;
        for (target, tables) in targets {
            let tables = tables.as_table().ok_or_else(|| {
                Error::Manifest(format!("Cargo.toml [target.{target}] is not a table"))
            })?;
            append_dependencies(&mut deps, tables, Some(target))?;
        }
    }
    Ok(PublishMetadata {
        name: string_field(package, "name")?,
        vers: string_field(package, "version")?,
        deps,
        features: root
            .get("features")
            .cloned()
            .unwrap_or_else(|| toml::Value::Table(Default::default())),
        links: package
            .get("links")
            .and_then(toml::Value::as_str)
            .map(str::to_owned),
        rust_version: package
            .get("rust-version")
            .and_then(toml::Value::as_str)
            .map(str::to_owned),
    })
}

pub fn read_metadata(crate_path: &Path) -> Result<PublishMetadata> {
    let file = File::open(crate_path).map_err(|source| io(crate_path, source))?;
    let mut archive = tar::Archive::new(GzDecoder::new(file));
    let entries = archive.entries().map_err(|source| io(crate_path, source))?;
    for entry in entries {
        let mut entry = entry.map_err(|source| io(crate_path, source))?;
        let path = entry.path().map_err(|source| io(crate_path, source))?;
        if path.file_name().is_some_and(|name| name == "Cargo.toml")
            && path.components().count() == 2
        {
            let mut body = String::new();
            entry
                .read_to_string(&mut body)
                .map_err(|source| io(crate_path, source))?;
            let manifest = toml::from_str(&body).map_err(|source| Error::Toml {
                path: crate_path.to_owned(),
                source,
            })?;
            return metadata_from_manifest(&manifest);
        }
    }
    Err(Error::Manifest(format!(
        "{} has no root Cargo.toml",
        crate_path.display()
    )))
}

pub fn sha256_hex(path: &Path) -> Result<String> {
    let bytes = std::fs::read(path).map_err(|source| io(path, source))?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

pub fn publish_body(crate_path: &Path) -> Result<(PublishMetadata, Vec<u8>)> {
    let metadata = read_metadata(crate_path)?;
    let json = serde_json::to_vec(&metadata).map_err(|source| Error::Json {
        path: crate_path.to_owned(),
        source,
    })?;
    let tarball = std::fs::read(crate_path).map_err(|source| io(crate_path, source))?;
    let mut body = Vec::with_capacity(8 + json.len() + tarball.len());
    body.extend_from_slice(&(json.len() as u32).to_le_bytes());
    body.extend_from_slice(&json);
    body.extend_from_slice(&(tarball.len() as u32).to_le_bytes());
    body.extend_from_slice(&tarball);
    Ok((metadata, body))
}

pub fn publish(crate_path: &Path, base_url: &str, token: &str) -> Result<u16> {
    let (metadata, body) = publish_body(crate_path)?;
    let url = format!("{}/api/v1/crates/new", base_url.trim_end_matches('/'));
    let response = ureq::builder()
        .timeout(Duration::from_secs(60))
        .redirects(0)
        .build()
        .put(&url)
        .set("Authorization", token)
        .send_bytes(&body);
    match response {
        Ok(response) => Ok(response.status()),
        Err(ureq::Error::Status(status, response)) => Err(Error::Rejected {
            name: metadata.name,
            version: metadata.vers,
            status,
            detail: response.into_string().unwrap_or_default(),
        }),
        Err(ureq::Error::Transport(source)) => Err(Error::Transport {
            name: metadata.name,
            version: metadata.vers,
            source: Box::new(source),
        }),
    }
}

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

pub fn index_entry(crate_path: &Path) -> Result<IndexEntry> {
    let metadata = read_metadata(crate_path)?;
    let deps = metadata
        .deps
        .into_iter()
        .map(|dependency| {
            let renamed = dependency.explicit_name_in_toml;
            IndexDependency {
                name: renamed.clone().unwrap_or_else(|| dependency.name.clone()),
                req: dependency.version_req,
                features: dependency.features,
                optional: dependency.optional,
                default_features: dependency.default_features,
                target: dependency.target,
                kind: dependency.kind,
                registry: dependency.registry,
                package: renamed.map(|_| dependency.name),
            }
        })
        .collect();
    Ok(IndexEntry {
        name: metadata.name,
        vers: metadata.vers,
        deps,
        cksum: sha256_hex(crate_path)?,
        features: metadata.features,
        yanked: false,
        links: metadata.links,
    })
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct MintCrate {
    #[serde(rename = "crate")]
    name: String,
    wasix_version: String,
    crate_file: String,
}

#[derive(Debug, Deserialize)]
struct MintManifest {
    crates: Vec<MintCrate>,
}

#[derive(Debug)]
pub struct SparseIndexReceipt {
    pub entries: usize,
    pub crates: usize,
}

pub fn sparse_index(
    mint: &Path,
    output: &Path,
    base_url: &str,
    only: &[String],
) -> Result<SparseIndexReceipt> {
    let manifest_path = mint.join("manifest.json");
    let manifest: MintManifest = serde_json::from_slice(
        &std::fs::read(&manifest_path).map_err(|source| io(&manifest_path, source))?,
    )
    .map_err(|source| Error::Json {
        path: manifest_path,
        source,
    })?;
    let wanted: BTreeSet<&str> = only.iter().map(String::as_str).collect();
    let selected: Vec<_> = manifest
        .crates
        .into_iter()
        .filter(|entry| {
            wanted.is_empty()
                || wanted.contains(format!("{}@{}", entry.name, entry.wasix_version).as_str())
        })
        .collect();
    if !wanted.is_empty() {
        let found: BTreeSet<String> = selected
            .iter()
            .map(|entry| format!("{}@{}", entry.name, entry.wasix_version))
            .collect();
        let missing: Vec<_> = wanted
            .iter()
            .filter(|spec| !found.contains(**spec))
            .copied()
            .collect();
        if !missing.is_empty() {
            return Err(Error::Manifest(format!(
                "not in the mint: {}",
                missing.join(", ")
            )));
        }
    }
    if selected.is_empty() {
        return Err(Error::Manifest("nothing selected".into()));
    }
    std::fs::create_dir_all(output).map_err(|source| io(output, source))?;
    let config_path = output.join("config.json");
    let config = serde_json::json!({
        "dl": format!("{}/dl/{{crate}}/{{version}}.crate", base_url.trim_end_matches('/'))
    });
    let mut config = serde_json::to_vec(&config).map_err(|source| Error::Json {
        path: config_path.clone(),
        source,
    })?;
    config.push(b'\n');
    std::fs::write(&config_path, config).map_err(|source| io(&config_path, source))?;

    let entries = selected.len();
    let mut lines: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for mint_entry in selected {
        let source = mint.join("crates").join(mint_entry.crate_file);
        let record = index_entry(&source)?;
        let json = serde_json::to_string(&record).map_err(|error| Error::Json {
            path: source.clone(),
            source: error,
        })?;
        lines.entry(record.name.clone()).or_default().push(json);
        let destination = output
            .join("dl")
            .join(&record.name)
            .join(format!("{}.crate", record.vers));
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent).map_err(|source| io(parent, source))?;
        }
        std::fs::copy(&source, &destination).map_err(|source| io(&destination, source))?;
    }
    for (name, records) in &lines {
        let destination = output.join(index_path(name));
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent).map_err(|source| io(parent, source))?;
        }
        let body = format!("{}\n", records.join("\n"));
        std::fs::write(&destination, body).map_err(|source| io(&destination, source))?;
    }
    Ok(SparseIndexReceipt {
        entries,
        crates: lines.len(),
    })
}

#[cfg(test)]
mod tests {
    use std::io::Write;

    use flate2::Compression;
    use flate2::write::GzEncoder;

    use super::*;

    fn fixture(manifest: &str) -> (PathBuf, PathBuf) {
        let root = std::env::temp_dir().join(format!(
            "cargo-registry-wire-{}-{}",
            std::process::id(),
            std::thread::current().name().unwrap_or("test")
        ));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let crate_path = root.join("probe-1.2.3.crate");
        let file = File::create(&crate_path).unwrap();
        let encoder = GzEncoder::new(file, Compression::default());
        let mut archive = tar::Builder::new(encoder);
        let mut header = tar::Header::new_gnu();
        header.set_size(manifest.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        archive
            .append_data(&mut header, "probe-1.2.3/Cargo.toml", manifest.as_bytes())
            .unwrap();
        archive
            .into_inner()
            .unwrap()
            .finish()
            .unwrap()
            .flush()
            .unwrap();
        (root, crate_path)
    }

    const MANIFEST: &str = r#"
[package]
name = "probe"
version = "1.2.3"
links = "probe"
rust-version = "1.80"

[dependencies]
plain = "1"
alias = { package = "actual", version = "2", features = ["one"], optional = true, default-features = false, registry = "other" }

[dev-dependencies]
dev = "3"

[build-dependencies]
build = "4"

[target.'cfg(unix)'.dependencies]
unix = "5"

[features]
default = ["plain/std"]
"#;

    #[test]
    fn one_manifest_drives_publish_and_index_metadata() {
        let (root, crate_path) = fixture(MANIFEST);
        let metadata = read_metadata(&crate_path).unwrap();
        assert_eq!(metadata.name, "probe");
        assert_eq!(metadata.vers, "1.2.3");
        assert_eq!(metadata.rust_version.as_deref(), Some("1.80"));
        assert_eq!(metadata.deps.len(), 5);
        let alias = metadata
            .deps
            .iter()
            .find(|dep| dep.name == "actual")
            .unwrap();
        assert_eq!(alias.explicit_name_in_toml.as_deref(), Some("alias"));
        assert!(!alias.default_features);
        assert_eq!(alias.registry.as_deref(), Some("other"));
        let unix = metadata.deps.iter().find(|dep| dep.name == "unix").unwrap();
        assert_eq!(unix.target.as_deref(), Some("cfg(unix)"));

        let index = index_entry(&crate_path).unwrap();
        let alias = index.deps.iter().find(|dep| dep.name == "alias").unwrap();
        assert_eq!(alias.package.as_deref(), Some("actual"));
        assert_eq!(index.links.as_deref(), Some("probe"));
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn publish_body_frames_json_and_tarball() {
        let (root, crate_path) = fixture(MANIFEST);
        let (_, body) = publish_body(&crate_path).unwrap();
        let json_len = u32::from_le_bytes(body[0..4].try_into().unwrap()) as usize;
        let metadata: serde_json::Value = serde_json::from_slice(&body[4..4 + json_len]).unwrap();
        assert_eq!(metadata["name"], "probe");
        let tar_len_at = 4 + json_len;
        let tar_len =
            u32::from_le_bytes(body[tar_len_at..tar_len_at + 4].try_into().unwrap()) as usize;
        assert_eq!(body.len(), tar_len_at + 4 + tar_len);
        assert_eq!(&body[tar_len_at + 4..], std::fs::read(&crate_path).unwrap());
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn sparse_index_validates_selection_and_copies_payload() {
        let (root, crate_path) = fixture(MANIFEST);
        let mint = root.join("mint");
        std::fs::create_dir_all(mint.join("crates")).unwrap();
        std::fs::copy(&crate_path, mint.join("crates/probe.crate")).unwrap();
        std::fs::write(
            mint.join("manifest.json"),
            r#"{"crates":[{"crate":"probe","wasixVersion":"1.2.3","crateFile":"probe.crate"}]}"#,
        )
        .unwrap();
        let output = root.join("site");
        let receipt = sparse_index(
            &mint,
            &output,
            "https://example.invalid/",
            &["probe@1.2.3".into()],
        )
        .unwrap();
        assert_eq!(receipt.entries, 1);
        assert_eq!(receipt.crates, 1);
        assert!(output.join("pr/ob/probe").is_file());
        assert_eq!(
            std::fs::read(output.join("dl/probe/1.2.3.crate")).unwrap(),
            std::fs::read(crate_path).unwrap()
        );
        assert!(
            sparse_index(&mint, &root.join("bad"), "x", &["missing@1".into()])
                .unwrap_err()
                .to_string()
                .contains("not in the mint")
        );
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn index_paths_match_cargo_layout() {
        assert_eq!(index_path("a"), "1/a");
        assert_eq!(index_path("ab"), "2/ab");
        assert_eq!(index_path("abc"), "3/a/abc");
        assert_eq!(index_path("Probe"), "pr/ob/probe");
    }
}
