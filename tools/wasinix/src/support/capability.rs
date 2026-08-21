//! Optional external programs are selected here from a closed set. A packaged
//! CLI resolves absent programs from its own locked flake; a development CLI
//! uses the current checkout. Callers receive an exact executable path and
//! cannot choose another installable.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::Command;
use std::sync::{Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::support::error::{Error, Result};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Capability {
    Aws,
    Python,
    Rclone,
    Wasmer,
}

struct Spec {
    name: &'static str,
    output: &'static str,
    executable: &'static str,
}

impl Capability {
    fn spec(self) -> Spec {
        match self {
            Capability::Aws => Spec {
                name: "AWS CLI",
                output: "wasinix-capability-aws",
                executable: "aws",
            },
            Capability::Python => Spec {
                name: "Python",
                output: "wasinix-capability-python",
                executable: "python3",
            },
            Capability::Rclone => Spec {
                name: "rclone",
                output: "wasinix-capability-rclone",
                executable: "rclone",
            },
            Capability::Wasmer => Spec {
                name: "Wasmer",
                output: "wasinix-capability-wasmer",
                executable: "wasmer",
            },
        }
    }

    pub fn command(self) -> Result<Command> {
        Ok(Command::new(resolve(self)?))
    }
}

fn cache() -> &'static Mutex<BTreeMap<Capability, PathBuf>> {
    static CACHE: OnceLock<Mutex<BTreeMap<Capability, PathBuf>>> = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(BTreeMap::new()))
}

fn cached(capability: Capability) -> Result<Option<PathBuf>> {
    cache()
        .lock()
        .map(|paths| paths.get(&capability).cloned())
        .map_err(|_| Error::Failure("capability cache lock was poisoned".into()))
}

fn remember(capability: Capability, path: PathBuf) -> Result<PathBuf> {
    cache()
        .lock()
        .map_err(|_| Error::Failure("capability cache lock was poisoned".into()))?
        .insert(capability, path.clone());
    Ok(path)
}

fn resolve(capability: Capability) -> Result<PathBuf> {
    if let Some(path) = cached(capability)? {
        return Ok(path);
    }
    let spec = capability.spec();
    if crate::support::env::on_path(spec.executable) {
        return remember(capability, PathBuf::from(spec.executable));
    }

    let flake = match crate::support::env::capability_flake() {
        Some(flake) => flake,
        None => crate::support::git::repo_root().map_err(|_| {
            Error::Request(format!(
                "{} is not on PATH and no packaged capability source is set; run from the wasinix checkout or use a packaged wasinix",
                spec.executable
            ))
        })?,
    };
    let installable = format!("{}#{}", flake.display(), spec.output);
    crate::support::ui::fact(
        "capability",
        format!("realising {} from {installable}", spec.name),
    );
    let started = Instant::now();
    let paths = crate::support::nix::Invocation::flake("build", &installable)
        .arg("--no-link")
        .option("max-jobs", "0")
        .timeout(crate::support::env::build_timeout()?.unwrap_or(Duration::from_secs(30 * 60)))
        .out_paths(&format!("resolving the {} capability", spec.name))?;
    let [output] = paths.as_slice() else {
        return Err(Error::Failure(format!(
            "{installable} produced {} outputs, expected one",
            paths.len()
        )));
    };
    let executable = output.join("bin").join(spec.executable);
    if !executable.is_file() {
        return Err(Error::Failure(format!(
            "{} capability has no {}",
            spec.name,
            executable.display()
        )));
    }
    crate::support::ui::fact(
        "capability",
        format!(
            "{} ready in {} ({})",
            spec.name,
            crate::support::format::duration(started.elapsed().as_secs_f64()),
            output.display()
        ),
    );
    remember(capability, executable)
}

#[cfg(test)]
mod tests {
    use super::Capability;

    #[test]
    fn every_capability_has_a_distinct_fixed_output() {
        let capabilities = [
            Capability::Aws,
            Capability::Python,
            Capability::Rclone,
            Capability::Wasmer,
        ];
        let outputs: std::collections::BTreeSet<_> = capabilities
            .iter()
            .map(|capability| capability.spec().output)
            .collect();
        assert_eq!(outputs.len(), capabilities.len());
        assert!(outputs
            .iter()
            .all(|output| output.starts_with("wasinix-capability-")));
        let flake = include_str!("../../../../flake.nix");
        for output in outputs {
            assert!(flake.contains(&format!("{output} =")), "{output}");
        }
    }
}
