//! Optional external programs are selected here from a closed set. A packaged
//! CLI resolves absent programs from its own locked flake; a development CLI
//! uses the current checkout. Callers receive an exact executable path and
//! cannot choose another installable.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

use crate::support::error::{Error, Result};

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum Capability {
    Aws,
    Python,
    PythonIndex,
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
            Capability::PythonIndex => Spec {
                name: "Python registry indexer",
                output: "wasinix-capability-python-index",
                executable: "wasinix-python-index",
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

    pub fn command(self) -> Result<crate::support::tools::Process> {
        Ok(crate::support::tools::Process::new(self.path()?))
    }

    pub fn path(self) -> Result<PathBuf> {
        resolve(self)
    }
}

#[derive(Clone)]
enum Resolution {
    Resolving,
    Ready(PathBuf),
    Failed { message: String, request: bool },
}

#[derive(Default)]
struct Resolver {
    resolutions: BTreeMap<Capability, Resolution>,
    anticipated: BTreeSet<Capability>,
    needed: BTreeSet<Capability>,
    waited: BTreeSet<Capability>,
}

fn registry() -> &'static (Mutex<Resolver>, Condvar) {
    static REGISTRY: OnceLock<(Mutex<Resolver>, Condvar)> = OnceLock::new();
    REGISTRY.get_or_init(|| (Mutex::new(Resolver::default()), Condvar::new()))
}

fn may_use_path() -> Result<bool> {
    Ok(crate::support::env::capabilities_on_path()?
        || crate::support::env::capability_flake().is_none())
}

fn resolve(capability: Capability) -> Result<PathBuf> {
    let spec = capability.spec();
    let (lock, ready) = registry();
    let mut resolver = lock
        .lock()
        .map_err(|_| Error::Failure("capability resolver lock was poisoned".into()))?;
    resolver.needed.insert(capability);
    let mut announced_wait = false;
    loop {
        match resolver.resolutions.get(&capability).cloned() {
            Some(Resolution::Ready(path)) => return Ok(path),
            Some(Resolution::Failed { message, request }) => {
                return Err(if request {
                    Error::Request(message)
                } else {
                    Error::Failure(message)
                });
            }
            Some(Resolution::Resolving) => {
                if resolver.anticipated.contains(&capability) && !announced_wait {
                    crate::support::ui::fact("capability", format!("waiting for {}", spec.name));
                    resolver.waited.insert(capability);
                    announced_wait = true;
                }
                resolver = ready
                    .wait(resolver)
                    .map_err(|_| Error::Failure("capability resolver lock was poisoned".into()))?;
            }
            None => {
                if may_use_path()? && crate::support::env::on_path(spec.executable) {
                    let path = PathBuf::from(spec.executable);
                    resolver
                        .resolutions
                        .insert(capability, Resolution::Ready(path.clone()));
                    return Ok(path);
                }
                resolver
                    .resolutions
                    .insert(capability, Resolution::Resolving);
                drop(resolver);
                crate::support::ui::fact("capability", format!("realising {}", spec.name));
                finish(&[capability], realise(&[capability], None, None));
                resolver = lock
                    .lock()
                    .map_err(|_| Error::Failure("capability resolver lock was poisoned".into()))?;
            }
        }
    }
}

fn capability_flake() -> Result<PathBuf> {
    if let Some(flake) = crate::support::env::capability_flake() {
        return Ok(flake);
    }
    crate::support::git::repo_root().map_err(|_| {
        Error::Request(
            "no packaged capability source is set; run from the wasinix checkout or use a packaged wasinix"
                .into(),
        )
    })
}

fn realise(
    capabilities: &[Capability],
    pid: Option<&AtomicU32>,
    cancelled: Option<&AtomicBool>,
) -> Result<Vec<PathBuf>> {
    let started = Instant::now();
    let flake = capability_flake()?;
    let installables: Vec<String> = capabilities
        .iter()
        .map(|capability| format!("{}#{}", flake.display(), capability.spec().output))
        .collect();
    let mut invocation = crate::support::nix::Invocation::flake("build", &installables[0])
        .arg("--no-link")
        .arg("--print-out-paths")
        .option("max-jobs", "0")
        .timeout(crate::support::env::build_timeout()?.unwrap_or(Duration::from_secs(30 * 60)));
    invocation = invocation.operands(installables.iter().skip(1));
    let completion = invocation.run_with_output_started(
        |command| {
            command
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped());
        },
        |child_pid| {
            if let Some(pid) = pid {
                pid.store(child_pid, Ordering::SeqCst);
            }
            if cancelled.is_some_and(|cancelled| cancelled.load(Ordering::SeqCst)) {
                let _ = crate::support::process::signal_group(child_pid, libc::SIGKILL);
            }
        },
    )?;
    if let Some(pid) = pid {
        pid.store(0, Ordering::SeqCst);
    }
    if cancelled.is_some_and(|cancelled| cancelled.load(Ordering::SeqCst)) {
        return Err(Error::Failure("capability prewarm was cancelled".into()));
    }
    let output = match completion {
        crate::support::tools::Completion::Finished(output) => output,
        crate::support::tools::Completion::TimedOut(_) => {
            return Err(Error::Failure(format!(
                "capability resolution timed out after {}",
                crate::support::format::duration(started.elapsed().as_secs_f64())
            )));
        }
    };
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let diagnostics = if stderr.trim().is_empty() {
            String::from_utf8_lossy(&output.stdout)
        } else {
            stderr
        };
        return Err(Error::Failure(format!(
            "resolving capabilities: {}",
            crate::support::tools::diagnostics_tail(&diagnostics)
        )));
    }
    let paths: Vec<PathBuf> = String::from_utf8_lossy(&output.stdout)
        .split_whitespace()
        .map(PathBuf::from)
        .collect();
    if paths.is_empty() {
        return Err(Error::Failure(
            "capability resolution reported no output paths".into(),
        ));
    }
    crate::support::ui::fact(
        "capability",
        format!(
            "{} ready in {}",
            capabilities
                .iter()
                .map(|capability| capability.spec().name)
                .collect::<Vec<_>>()
                .join(", "),
            crate::support::format::duration(started.elapsed().as_secs_f64())
        ),
    );
    Ok(paths)
}

fn finish(capabilities: &[Capability], outputs: Result<Vec<PathBuf>>) {
    let (lock, ready) = registry();
    let Ok(mut resolver) = lock.lock() else {
        return;
    };
    for capability in capabilities {
        let spec = capability.spec();
        let resolution = match &outputs {
            Ok(outputs) => outputs
                .iter()
                .map(|output| output.join("bin").join(spec.executable))
                .find(|path| path.is_file())
                .map(Resolution::Ready)
                .unwrap_or_else(|| Resolution::Failed {
                    message: format!(
                        "{} capability outputs contain no bin/{}",
                        spec.name, spec.executable
                    ),
                    request: false,
                }),
            Err(error) => Resolution::Failed {
                message: error.to_string(),
                request: matches!(error, Error::Request(_)),
            },
        };
        resolver.resolutions.insert(*capability, resolution);
    }
    ready.notify_all();
}

pub struct Prewarm {
    capabilities: Vec<Capability>,
    cancelled: Arc<AtomicBool>,
    pid: Arc<AtomicU32>,
    worker: Option<std::thread::JoinHandle<()>>,
}

impl Prewarm {
    fn empty() -> Prewarm {
        Prewarm {
            capabilities: Vec::new(),
            cancelled: Arc::new(AtomicBool::new(false)),
            pid: Arc::new(AtomicU32::new(0)),
            worker: None,
        }
    }
}

pub fn prewarm(capabilities: impl IntoIterator<Item = Capability>) -> Result<Prewarm> {
    let capabilities: Vec<Capability> = capabilities
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if capabilities.is_empty() {
        return Ok(Prewarm::empty());
    }
    let (lock, _) = registry();
    let mut resolver = lock
        .lock()
        .map_err(|_| Error::Failure("capability resolver lock was poisoned".into()))?;
    let mut pending = Vec::new();
    for capability in &capabilities {
        resolver.anticipated.insert(*capability);
        if resolver.resolutions.contains_key(capability) {
            continue;
        }
        let spec = capability.spec();
        if may_use_path()? && crate::support::env::on_path(spec.executable) {
            resolver.resolutions.insert(
                *capability,
                Resolution::Ready(PathBuf::from(spec.executable)),
            );
        } else {
            resolver
                .resolutions
                .insert(*capability, Resolution::Resolving);
            pending.push(*capability);
        }
    }
    drop(resolver);
    if pending.is_empty() {
        return Ok(Prewarm {
            capabilities,
            cancelled: Arc::new(AtomicBool::new(false)),
            pid: Arc::new(AtomicU32::new(0)),
            worker: None,
        });
    }

    crate::support::ui::fact(
        "capability prewarm",
        pending
            .iter()
            .map(|capability| capability.spec().name)
            .collect::<Vec<_>>()
            .join(", "),
    );
    let cancelled = Arc::new(AtomicBool::new(false));
    let pid = Arc::new(AtomicU32::new(0));
    let worker_capabilities = pending;
    let worker_cancelled = Arc::clone(&cancelled);
    let worker_pid = Arc::clone(&pid);
    let worker = std::thread::spawn(move || {
        let outputs = realise(
            &worker_capabilities,
            Some(&worker_pid),
            Some(&worker_cancelled),
        );
        finish(&worker_capabilities, outputs);
    });
    Ok(Prewarm {
        capabilities,
        cancelled,
        pid,
        worker: Some(worker),
    })
}

impl Drop for Prewarm {
    fn drop(&mut self) {
        if let Some(worker) = self.worker.take() {
            if !worker.is_finished() {
                self.cancelled.store(true, Ordering::SeqCst);
                let pid = self.pid.load(Ordering::SeqCst);
                if pid != 0 {
                    let _ = crate::support::process::signal_group(pid, libc::SIGKILL);
                }
            }
            if worker.join().is_err() {
                crate::support::ui::warning("capability prewarm worker panicked");
            }
        }
        if crate::support::ui::verbosity() == crate::support::ui::Verbosity::Verbose {
            let (lock, _) = registry();
            if let Ok(resolver) = lock.lock() {
                let needed = self
                    .capabilities
                    .iter()
                    .filter(|capability| resolver.needed.contains(capability))
                    .count();
                let waited = self
                    .capabilities
                    .iter()
                    .filter(|capability| resolver.waited.contains(capability))
                    .count();
                let ready_at_first_use = self
                    .capabilities
                    .iter()
                    .filter(|capability| {
                        resolver.needed.contains(capability)
                            && !resolver.waited.contains(capability)
                            && matches!(
                                resolver.resolutions.get(capability),
                                Some(Resolution::Ready(_))
                            )
                    })
                    .count();
                let failed = self
                    .capabilities
                    .iter()
                    .filter(|capability| {
                        matches!(
                            resolver.resolutions.get(capability),
                            Some(Resolution::Failed { .. })
                        )
                    })
                    .count();
                crate::support::ui::note(format!(
                    "  capability prewarm: {} anticipated, {needed} needed, {ready_at_first_use} ready at first use, {waited} waited, {} unused, {failed} failed",
                    self.capabilities.len(),
                    self.capabilities.len().saturating_sub(needed)
                ));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::Capability;

    #[test]
    fn every_capability_has_a_distinct_fixed_output() {
        let capabilities = [
            Capability::Aws,
            Capability::Python,
            Capability::PythonIndex,
            Capability::Rclone,
            Capability::Wasmer,
        ];
        let outputs: std::collections::BTreeSet<_> = capabilities
            .iter()
            .map(|capability| capability.spec().output)
            .collect();
        assert_eq!(outputs.len(), capabilities.len());
        assert!(
            outputs
                .iter()
                .all(|output| output.starts_with("wasinix-capability-"))
        );
        let flake = include_str!("../../../../flake.nix");
        for output in outputs {
            assert!(flake.contains(&format!("{output} =")), "{output}");
        }
    }

    #[test]
    fn first_use_waits_for_the_anticipated_resolution() {
        let capability = Capability::Aws;
        let (lock, _) = super::registry();
        {
            let mut resolver = lock.lock().unwrap();
            resolver.anticipated.insert(capability);
            resolver
                .resolutions
                .insert(capability, super::Resolution::Resolving);
        }
        let user = std::thread::spawn(move || capability.command().unwrap());
        loop {
            if lock.lock().unwrap().needed.contains(&capability) {
                break;
            }
            std::thread::yield_now();
        }
        let scratch = crate::support::fs::Scratch::create("capability-test").unwrap();
        let bin = scratch.path().join("bin");
        crate::support::fs::create_dir_all(&bin).unwrap();
        crate::support::fs::write(&bin.join("aws"), b"test").unwrap();
        super::finish(&[capability], Ok(vec![scratch.path().to_path_buf()]));
        let command = user.join().unwrap();
        assert_eq!(command.program(), bin.join("aws"));
    }
}
