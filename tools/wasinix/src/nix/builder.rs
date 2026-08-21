//! Remote nix execution selected for this machine. The toolchain and the full
//! sweep are too expensive to build locally, and a stray system-default
//! builder can cost real money, so every caller derives its flags from the
//! shared remote registry.

use std::collections::BTreeMap;
use std::fs::OpenOptions;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;

use serde::{Deserialize, Serialize};

use crate::support::error::{Error, Result, io, request_error};
use crate::support::shell::expand_home;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, clap::ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum Capability {
    Builder,
    Store,
    Host,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize, clap::ValueEnum)]
#[serde(rename_all = "kebab-case")]
pub enum RouteKind {
    Local,
    Builder,
    Store,
    Host,
}

impl RouteKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Local => "local",
            Self::Builder => "builder",
            Self::Store => "store",
            Self::Host => "host",
        }
    }

    pub fn parse(value: &str) -> Result<RouteKind> {
        match value {
            "local" => Ok(Self::Local),
            "builder" => Ok(Self::Builder),
            "store" => Ok(Self::Store),
            "host" => Ok(Self::Host),
            other => request_error(format!(
                "unknown route \"{other}\"; routes are local, builder, store, host"
            )),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Builder {
    pub name: String,
    pub description: Option<String>,
    /// ssh target, user@hostname.
    pub host: String,
    /// The ssh key, read as the caller for a client-side remote store.
    pub key: PathBuf,
    /// The key path the nix-daemon uses, which runs as root and cannot read
    /// the caller's `~/.ssh`.
    pub daemon_key: String,
    pub system: String,
    pub max_jobs: String,
    pub features: String,
    /// The builder's ssh host key, a public-key line; `-` pins nothing.
    pub host_key: String,
    pub store_url: Option<String>,
    pub builders_spec: Option<String>,
    pub capabilities: Vec<Capability>,
    pub capacity: usize,
    pub max_load: Option<f64>,
    pub substituters: Vec<String>,
    pub trusted_public_keys: Vec<String>,
    pub route: Option<RouteKind>,
    pub eval_workers: Option<usize>,
    pub eval_memory: Option<usize>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct Registry {
    default: String,
    remotes: BTreeMap<String, Profile>,
    #[serde(default)]
    pub(crate) local: Option<LocalProfile>,
}

/// The `[local]` profile: persistent limits for `--on local`, each
/// overridable per invocation by its environment variable.
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LocalProfile {
    pub max_jobs: Option<usize>,
    pub eval_workers: Option<usize>,
    pub eval_memory: Option<usize>,
    /// Concurrent local runs; unset means unlimited, as before.
    pub capacity: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct Profile {
    description: Option<String>,
    host: String,
    key: String,
    daemon_key: Option<String>,
    system: Option<String>,
    max_jobs: Option<String>,
    features: Option<Vec<String>>,
    host_key: Option<String>,
    store: Option<String>,
    builders: Option<String>,
    capabilities: Vec<Capability>,
    capacity: Option<usize>,
    max_load: Option<f64>,
    substituters: Option<Vec<String>>,
    trusted_public_keys: Option<Vec<String>>,
    route: Option<RouteKind>,
    eval_workers: Option<usize>,
    eval_memory: Option<usize>,
}

fn or_home(dir: Option<PathBuf>, fallback: &str) -> Result<PathBuf> {
    Ok(match dir {
        Some(dir) => dir,
        None => crate::support::shell::home_dir()?.join(fallback),
    })
}

pub fn config_path() -> Result<PathBuf> {
    if crate::support::env::legacy_remotes_set() {
        return request_error(
            "WASINIX_REMOTES was renamed: set WASINIX_BUILDERS (the file is builders.toml now)",
        );
    }
    if let Some(path) = crate::support::env::wasinix_builders() {
        return Ok(path);
    }
    let config = or_home(crate::support::env::xdg_config_home(), ".config")?.join("wasinix");
    let path = config.join("builders.toml");
    if !path.exists() && config.join("remotes.toml").exists() {
        return request_error(format!(
            "remotes.toml was renamed: mv {} {}",
            config.join("remotes.toml").display(),
            path.display()
        ));
    }
    Ok(path)
}

pub fn runtime_dir() -> Result<PathBuf> {
    Ok(match crate::support::env::xdg_runtime_dir() {
        Some(path) => path.join("wasinix"),
        None => or_home(crate::support::env::xdg_state_home(), ".local/state")?.join("wasinix/run"),
    })
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn read_registry() -> Result<Option<Registry>> {
    let path = config_path()?;
    if !path.exists() {
        return Ok(None);
    }
    parse_registry(&crate::support::fs::read_to_string(&path)?, &path).map(Some)
}

pub(crate) fn parse_registry(text: &str, path: &Path) -> Result<Registry> {
    let registry: Registry = toml::from_str(text)
        .map_err(|error| Error::Request(format!("{}: {error}", path.display())))?;
    if !valid_name(&registry.default) {
        return request_error(format!(
            "invalid default remote name {:?}",
            registry.default
        ));
    }
    if registry.remotes.keys().any(|name| !valid_name(name)) {
        return request_error(format!(
            "remote names in {} may contain only letters, digits, '-' and '_'",
            path.display()
        ));
    }
    // `--on local` and the local lease directory both own the name.
    if registry.remotes.contains_key("local") {
        return request_error(format!(
            "{}: \"local\" is not a remote name; its limits go in the [local] table",
            path.display()
        ));
    }
    if let Some(local) = &registry.local {
        if [
            local.max_jobs,
            local.eval_workers,
            local.eval_memory,
            local.capacity,
        ]
        .contains(&Some(0))
        {
            return request_error(format!(
                "{}: [local] limits must be positive integers",
                path.display()
            ));
        }
    }
    Ok(registry)
}

/// The `[local]` profile, empty when no config file or table exists. Inert
/// under test, where the developer's real config would leak into limits.
pub fn local_profile() -> Result<LocalProfile> {
    if cfg!(test) {
        return Ok(LocalProfile::default());
    }
    Ok(read_registry()?
        .and_then(|registry| registry.local)
        .unwrap_or_default())
}

fn from_profile(name: String, profile: Profile) -> Result<Builder> {
    if profile.capabilities.is_empty() {
        return request_error(format!("remote {name:?} has no capabilities"));
    }
    if profile.eval_workers == Some(0) || profile.eval_memory == Some(0) {
        return request_error(format!(
            "remote {name:?} evaluation limits must be positive integers"
        ));
    }
    if profile.route == Some(RouteKind::Local) {
        return request_error(format!(
            "remote {name:?} cannot use local as its default route"
        ));
    }
    let key = expand_home(&profile.key)?;
    Ok(Builder {
        name,
        description: profile.description,
        host: profile.host,
        daemon_key: profile
            .daemon_key
            .unwrap_or_else(|| key.to_string_lossy().into_owned()),
        key,
        system: profile
            .system
            .unwrap_or_else(|| crate::support::nix::SYSTEM.to_string()),
        max_jobs: profile.max_jobs.unwrap_or_else(|| "1".to_string()),
        features: profile.features.unwrap_or_default().join(","),
        host_key: profile.host_key.unwrap_or_else(|| "-".to_string()),
        store_url: profile.store,
        builders_spec: profile.builders,
        capabilities: profile.capabilities,
        capacity: profile.capacity.unwrap_or(1),
        max_load: profile.max_load,
        substituters: profile.substituters.unwrap_or_default(),
        trusted_public_keys: profile.trusted_public_keys.unwrap_or_default(),
        route: profile.route,
        eval_workers: profile.eval_workers,
        eval_memory: profile.eval_memory,
    })
}

/// `KEY=value` lines, which is also what a shell would read. A line that is
/// neither empty, a comment, nor an assignment is a mistake worth naming.
fn legacy_settings(path: &Path, text: &str) -> Result<BTreeMap<String, String>> {
    let mut settings = BTreeMap::new();
    for line in text.lines().map(str::trim) {
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            return request_error(format!(
                "{}: line {line:?} is not a KEY=value assignment",
                path.display()
            ));
        };
        let value = value.trim();
        let value = value
            .strip_prefix('"')
            .and_then(|rest| rest.strip_suffix('"'))
            .unwrap_or(value);
        settings.insert(key.trim().to_string(), value.to_string());
    }
    Ok(settings)
}

fn load_legacy(repo: &Path) -> Result<Builder> {
    let path = repo.join(".remote-builder");
    if !path.is_file() {
        return request_error(format!(
            "no remote is configured: create {} (copy builders.toml.example) or the legacy {}",
            config_path()?.display(),
            path.display()
        ));
    }
    let settings = legacy_settings(&path, &crate::support::fs::read_to_string(&path)?)?;
    let required = |name: &str| -> Result<String> {
        match settings.get(name) {
            Some(value) if !value.is_empty() => Ok(value.clone()),
            _ => request_error(format!("{name} unset in {}", path.display())),
        }
    };
    let key = expand_home(&required("KEY")?)?;
    Ok(Builder {
        name: "legacy".to_string(),
        description: None,
        host: required("HOST")?,
        daemon_key: settings
            .get("DAEMON_KEY")
            .cloned()
            .unwrap_or_else(|| key.to_string_lossy().into_owned()),
        key,
        system: settings
            .get("SYSTEM")
            .cloned()
            .unwrap_or_else(|| crate::support::nix::SYSTEM.to_string()),
        max_jobs: settings
            .get("MAXJOBS")
            .cloned()
            .unwrap_or_else(|| "1".to_string()),
        features: settings.get("FEATURES").cloned().unwrap_or_default(),
        host_key: settings
            .get("HOSTKEY")
            .cloned()
            .unwrap_or_else(|| "-".to_string()),
        store_url: None,
        builders_spec: None,
        capabilities: vec![Capability::Builder, Capability::Store, Capability::Host],
        capacity: 1,
        max_load: None,
        substituters: Vec::new(),
        trusted_public_keys: Vec::new(),
        route: None,
        eval_workers: None,
        eval_memory: None,
    })
}

/// Configured remote names, for shell completion: silent on any problem,
/// since a completer must never error a keystroke.
pub fn remote_names() -> Vec<String> {
    read_registry()
        .ok()
        .flatten()
        .map(|registry| registry.remotes.keys().cloned().collect())
        .unwrap_or_default()
}

pub fn load(repo: &Path, selected: Option<&str>) -> Result<Builder> {
    let selected = selected
        .map(str::to_string)
        .or(crate::support::env::wasinix_remote()?);
    let Some(mut registry) = read_registry()? else {
        if selected.is_some() {
            return request_error(format!(
                "{} does not exist, so no named remote can be selected",
                config_path()?.display()
            ));
        }
        return load_legacy(repo);
    };
    let name = selected.unwrap_or_else(|| registry.default.clone());
    let profile = match registry.remotes.remove(&name) {
        Some(profile) => profile,
        None => {
            let known: Vec<String> = registry.remotes.keys().cloned().collect();
            return request_error(format!(
                "remote {name:?} is not configured; have: {}",
                known.join(", ")
            ));
        }
    };
    from_profile(name, profile)
}

pub fn all(repo: &Path) -> Result<Vec<(Builder, bool)>> {
    let Some(registry) = read_registry()? else {
        return Ok(vec![(load_legacy(repo)?, true)]);
    };
    registry
        .remotes
        .into_iter()
        .map(|(name, profile)| {
            let default = name == registry.default;
            Ok((from_profile(name, profile)?, default))
        })
        .collect()
}

impl Builder {
    /// For store-routed builds and `nix copy --to`.
    pub fn store(&self) -> String {
        self.store_url
            .clone()
            .unwrap_or_else(|| format!("ssh-ng://{}?ssh-key={}", self.host, self.key.display()))
    }

    /// For `nix build --builders ... --max-jobs 0`, where the daemon connects.
    pub fn builders(&self) -> String {
        if let Some(spec) = &self.builders_spec {
            return spec.clone();
        }
        format!(
            "ssh-ng://{} {} {} {} 2 {} - {}",
            self.host, self.system, self.daemon_key, self.max_jobs, self.features, self.host_key
        )
    }

    pub fn supports(&self, capability: Capability) -> bool {
        self.capabilities.contains(&capability)
    }

    pub fn default_route(&self) -> RouteKind {
        if self.supports(Capability::Host) {
            RouteKind::Host
        } else if self.supports(Capability::Store) {
            RouteKind::Store
        } else {
            RouteKind::Builder
        }
    }

    pub fn nix_options(&self) -> Vec<String> {
        let mut options = Vec::new();
        if !self.substituters.is_empty() {
            options.extend([
                "--option".to_string(),
                "extra-substituters".to_string(),
                self.substituters.join(" "),
            ]);
        }
        if !self.trusted_public_keys.is_empty() {
            options.extend([
                "--option".to_string(),
                "extra-trusted-public-keys".to_string(),
                self.trusted_public_keys.join(" "),
            ]);
        }
        options
    }

    /// The one ssh option set every connection to this builder uses: batch
    /// mode, a bounded connect timeout, and the pinned host key when the
    /// registry carries one (accept-new only when it does not).
    ///
    /// See [`known_hosts_line`] for the host key's format.
    fn ssh_options(&self, cmd: &mut Command) -> Result<()> {
        cmd.arg("-i").arg(&self.key);
        cmd.args(["-o", "BatchMode=yes", "-o", "ConnectTimeout=8"]);
        if self.host_key == "-" {
            cmd.args(["-o", "StrictHostKeyChecking=accept-new"]);
        } else {
            let known = runtime_dir()?.join(format!("known-hosts-{}", self.name));
            let hostname = self.host.split('@').next_back().unwrap_or(&self.host);
            crate::support::fs::write(
                &known,
                known_hosts_line(hostname, &self.host_key).as_bytes(),
            )?;
            cmd.args(["-o", "StrictHostKeyChecking=yes"]);
            cmd.arg("-o")
                .arg(format!("UserKnownHostsFile={}", known.display()));
        }
        Ok(())
    }

    pub fn ssh(&self) -> Result<Command> {
        let mut cmd = Command::new("ssh");
        self.ssh_options(&mut cmd)?;
        cmd.arg(&self.host);
        Ok(cmd)
    }

    pub fn scp(&self) -> Result<Command> {
        let mut cmd = Command::new("scp");
        self.ssh_options(&mut cmd)?;
        Ok(cmd)
    }

    pub fn reachable(&self) -> Result<()> {
        let deadline = Deadline::Probe;
        let mut cmd = self.ssh()?;
        cmd.arg("true");
        let status = crate::support::tools::status_timeout(
            &mut cmd,
            deadline.timeout(),
        )?;
        if !matches!(
            status,
            crate::support::tools::Completion::Finished(status) if status.success()
        ) {
            return request_error(format!(
                "cannot reach {} with {}",
                self.host,
                self.key.display()
            ));
        }
        Ok(())
    }

    pub fn ssh_output(&self, deadline: Deadline, script: &str) -> Result<String> {
        let mut cmd = self.ssh()?;
        cmd.arg(script);
        let context = format!("remote command on {}", self.host);
        crate::support::tools::checked_text_timeout(&mut cmd, &context, deadline.timeout())
    }

    /// Like [`ssh_output`](Self::ssh_output), but the script arrives on
    /// stdin (`bash -s`), so a secret line never appears in the remote argv.
    pub fn ssh_stdin_output(&self, deadline: Deadline, script: &str) -> Result<String> {
        use std::io::Write;
        let mut cmd = self.ssh()?;
        cmd.arg("bash -s")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped());
        let mut child = crate::support::tools::spawn(&mut cmd)?;
        child
            .take_stdin()
            .expect("stdin was piped")
            .write_all(script.as_bytes())
            .map_err(|error| Error::Failure(format!("writing to {}: {error}", self.host)))?;
        let completion = child
            .wait_with_output_timeout(deadline.timeout())
            .map_err(|error| Error::Failure(format!("remote command on {}: {error}", self.host)))?;
        let output = match completion {
            crate::support::tools::Completion::Finished(output) => output,
            crate::support::tools::Completion::TimedOut(_) => {
                return Err(Error::Failure(format!(
                    "remote command on {} timed out",
                    self.host
                )));
            }
        };
        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr);
            return Err(Error::Failure(format!(
                "remote command on {}: {}",
                self.host,
                crate::support::error::tail(&stderr, 800)
            )));
        }
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    }
}

/// A known_hosts entry for a registry host key. The registry stores the key
/// the way the nix builders spec does, base64 over the whole "type key" line;
/// a raw "type key" value never decodes as base64, so both forms are taken.
pub(crate) fn known_hosts_line(hostname: &str, host_key: &str) -> String {
    use base64::Engine;
    let key = base64::engine::general_purpose::STANDARD
        .decode(host_key.trim())
        .ok()
        .and_then(|bytes| String::from_utf8(bytes).ok())
        .filter(|text| text.contains(' '))
        .unwrap_or_else(|| host_key.to_string());
    format!("{hostname} {}\n", key.trim())
}

/// How long a remote command may take before it is a hang, not work.
/// ConnectTimeout bounds only the handshake; without one of these, a poll
/// that never returns blocks its loop forever.
#[derive(Clone, Copy)]
pub enum Deadline {
    /// A liveness or metadata read: seconds.
    Probe,
    /// One observe-poll round: quiet by contract, since it fires every few
    /// seconds for the whole run.
    Poll,
    /// The launch script, which builds the launcher on the host.
    Launch,
}

impl Deadline {
    pub(crate) fn timeout(self) -> crate::support::tools::Timeout {
        let seconds = match self {
            Deadline::Probe | Deadline::Poll => 30,
            Deadline::Launch => 1800,
        };
        crate::support::tools::Timeout::new(
            std::time::Duration::from_secs(seconds),
        )
    }
}

#[derive(Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LeaseRecord {
    pid: u32,
    started_at: u64,
    /// The holder's kernel start time (/proc/<pid>/stat), so a recycled pid
    /// reads as a different process instead of holding the slot forever.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pid_started: Option<u64>,
}

#[derive(Debug)]
pub struct Lease {
    path: PathBuf,
}

impl Drop for Lease {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.path) {
            crate::support::ui::warning(format!(
                "could not release lease {}: {error}",
                self.path.display()
            ));
        }
    }
}

fn process_alive(pid: u32) -> bool {
    Path::new("/proc").join(pid.to_string()).exists()
}

/// Kernel start time of a live process, in clock ticks since boot; None when
/// the process is gone. The comm field may contain spaces, so fields count
/// from after its closing parenthesis (starttime is the 22nd overall).
fn process_start_ticks(pid: u32) -> Option<u64> {
    let stat =
        std::fs::read_to_string(Path::new("/proc").join(pid.to_string()).join("stat")).ok()?;
    let after_comm = stat.rsplit_once(')')?.1;
    after_comm.split_whitespace().nth(19)?.parse().ok()
}

pub fn acquire(builder: &Builder) -> Result<Lease> {
    let root = runtime_dir()?.join("leases").join(&builder.name);
    acquire_slots(
        &root,
        builder.capacity,
        &format!("remote {:?}", builder.name),
    )
}

/// A slot against the `[local]` capacity, so concurrent local runs cannot
/// oversubscribe the machine. `parse_registry` keeps the name free.
pub fn acquire_local(capacity: usize) -> Result<Lease> {
    let root = runtime_dir()?.join("leases").join("local");
    acquire_slots(&root, capacity, "local builds")
}

/// One slot out of `capacity` under `root`, stamped with this process's pid;
/// a slot whose recorded holder is dead is reclaimed. Fails loudly when all
/// slots are held, mirroring a build farm that refuses rather than queues.
pub fn acquire_slots(root: &Path, capacity: usize, what: &str) -> Result<Lease> {
    if capacity == 0 {
        return request_error(format!("{what} has zero capacity"));
    }
    crate::support::fs::create_dir_all(root)?;
    for slot in 0..capacity {
        let path = root.join(format!("{slot}.json"));
        match OpenOptions::new().write(true).create_new(true).open(&path) {
            Ok(mut file) => {
                let record = LeaseRecord {
                    pid: std::process::id(),
                    started_at: crate::support::time::unix_secs(),
                    pid_started: process_start_ticks(std::process::id()),
                };
                let text = serde_json::to_string(&record).map_err(|source| Error::Json {
                    path: path.clone(),
                    source,
                })?;
                file.write_all(text.as_bytes()).map_err(|e| io(&path, e))?;
                return Ok(Lease { path });
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                // A holder that died mid-write leaves an unparsable record; a
                // slot that cannot name a live holder is not held.
                let holder = crate::support::fs::read_to_string(&path)
                    .ok()
                    .and_then(|text| serde_json::from_str::<LeaseRecord>(&text).ok());
                let stale = match holder {
                    // A recorded start time pins the holder's identity; bare
                    // liveness is the fallback for records predating it.
                    Some(LeaseRecord {
                        pid,
                        pid_started: Some(started),
                        ..
                    }) => process_start_ticks(pid) != Some(started),
                    Some(record) => !process_alive(record.pid),
                    None => {
                        crate::support::ui::warning(format!(
                            "reclaiming unreadable lease {}",
                            path.display()
                        ));
                        true
                    }
                };
                if stale {
                    // Losing the removal race means another acquirer
                    // reclaimed the slot first, which is not a failure.
                    match std::fs::remove_file(&path) {
                        Ok(()) => {}
                        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                        Err(error) => return Err(io(&path, error)),
                    }
                    return acquire_slots(root, capacity, what);
                }
            }
            Err(error) => return Err(io(&path, error)),
        }
    }
    request_error(format!("{what} has all {capacity} lease slots in use"))
}

/// Shell fragment refusing a host whose load is already past the configured
/// ceiling, run before anything expensive ships to it.
pub fn load_check_script(builder: &Builder) -> String {
    builder.max_load.map_or_else(String::new, |limit| {
        format!(
            "current_load=$(cut -d' ' -f1 /proc/loadavg)\n\
             awk -v current_load=\"$current_load\" -v limit=\"{limit}\" 'BEGIN {{ exit !(current_load > limit) }}' && {{ echo \"remote load $current_load exceeds {limit}\" >&2; exit 75; }}\n"
        )
    })
}
