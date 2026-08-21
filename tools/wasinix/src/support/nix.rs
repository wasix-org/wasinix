//! Every nix invocation runs through this module. Construction classifies the
//! installable, so accept-flake-config is applied by what is evaluated, not
//! by caller memory; placement folds in through `.route`, so a command
//! cannot get the store without the builders guard; and every runner logs,
//! so the transcript reads as one thing.

use std::path::PathBuf;
use std::process::Command;
use std::time::Duration;

use serde_json::Value;

use crate::nix::route::Route;
use crate::support::error::{Error, Result};
use crate::support::process::CommandStatus;

pub const SYSTEM: &str = "x86_64-linux";

pub fn project_attr(path: &str) -> String {
    if path.is_empty() {
        format!("legacyPackages.{SYSTEM}")
    } else {
        format!("legacyPackages.{SYSTEM}.{path}")
    }
}

pub fn project_installable(flake: &str, path: &str) -> String {
    format!("{flake}#{}", project_attr(path))
}

pub fn canonical_webcs_apply(map: &str) -> String {
    // Revisions from before alias support have no packageKey and contain only
    // canonical entries, which keeps cross-revision comparisons evaluable.
    format!(
        "ws: builtins.mapAttrs ({map}) (builtins.listToAttrs (builtins.map \
         (name: {{ inherit name; value = ws.${{name}}; }}) (builtins.filter \
         (name: let p = ws.${{name}}; in !(p.passthru.wasmer ? packageKey) \
         || name == p.passthru.wasmer.packageKey) (builtins.attrNames ws))))"
    )
}

/// The shared binary cache, spelled once: rotating the key or moving the
/// bucket is an edit here and nowhere else. The workflows read the same
/// values through the nix-config emitter.
pub const CACHE_SUBSTITUTER: &str = "https://nix-cache.wasix.org";
pub const CACHE_PUBLIC_KEY: &str = "wasinix-1:jvsqbOJGsZxMvg97fuyNCWCc+t2nn6uHB47kQCGNmXI=";
pub const CACHE_BUCKET: &str = "wasinix-cache";
pub const CACHE_ENDPOINT: &str =
    "https://1541b1e8a3fc6ad155ce67ef38899700.r2.cloudflarestorage.com";

/// The s3 store uploads push to; reads go through the substituter.
pub fn cache_push_store() -> String {
    format!("s3://{CACHE_BUCKET}?region=auto&endpoint={CACHE_ENDPOINT}&compression=zstd")
}


/// Whether a stderr line is nix transfer chatter rather than a message: an
/// error excerpt taking the tail of a stream must not let hundreds of
/// `copying path` lines push the actual failure out of the window.
pub fn progress_noise(line: &str) -> bool {
    let line = line.trim_start();
    ["copying path '", "building '", "unpacking '", "querying info about", "downloading '"]
        .iter()
        .any(|prefix| line.starts_with(prefix))
}

/// The target Nix announces when automatic GC starts. Nix does not report
/// the amount eventually reclaimed, so callers must not present this as it.
pub fn auto_gc_requested_bytes(line: &str) -> Option<u64> {
    let rest = line.trim_start().strip_prefix("running auto-GC to free ")?;
    rest.strip_suffix(" bytes")?.parse().ok()
}

#[derive(Clone, Default)]
pub struct AutomaticGcObserver(std::sync::Arc<std::sync::Mutex<Vec<u64>>>);

impl AutomaticGcObserver {
    pub fn observe(&self, line: &[u8]) {
        if let Some(requested) = auto_gc_requested_bytes(String::from_utf8_lossy(line).trim_end()) {
            self.0
                .lock()
                .expect("automatic GC observations lock was poisoned")
                .push(requested);
        }
    }

    pub fn requested_bytes(&self) -> Vec<u64> {
        self.0
            .lock()
            .expect("automatic GC observations lock was poisoned")
            .clone()
    }
}

#[cfg(test)]
mod auto_gc_tests {
    #[test]
    fn parses_only_the_automatic_gc_announcement() {
        assert_eq!(
            super::auto_gc_requested_bytes("running auto-GC to free 10737418240 bytes"),
            Some(10_737_418_240)
        );
        assert_eq!(
            super::auto_gc_requested_bytes("warning: running auto-GC to free 12 bytes"),
            None
        );
        assert_eq!(super::auto_gc_requested_bytes("deleted 12 bytes"), None);

        let observer = super::AutomaticGcObserver::default();
        observer.observe(b"running auto-GC to free 42 bytes\n");
        assert_eq!(observer.requested_bytes(), vec![42]);
    }

    #[test]
    fn ci_does_not_override_store_gc() {
        let config = super::nix_config();
        assert!(!config.contains("min-free"));
        assert!(!config.contains("max-free"));
        assert!(!config.contains("keep-outputs"));
    }
}

/// The nix config block workflows install, from the same constants the
/// binary trusts.
pub fn nix_config() -> String {
    format!(
        "extra-substituters = {CACHE_SUBSTITUTER}\n\
         extra-trusted-public-keys = {CACHE_PUBLIC_KEY}\n\
         trusted-users = root runner\n"
    )
}

/// The flake to evaluate: `.` for this checkout, `path:...` for another.
pub struct Flake<'a>(pub &'a str);

impl Default for Flake<'_> {
    fn default() -> Self {
        Flake(".")
    }
}

/// The output of an unchecked run, for callers that parse failure output.
pub struct Probe {
    pub status: CommandStatus,
    pub stdout: Vec<u8>,
    pub stderr: String,
}

pub struct Invocation {
    program: String,
    interface: Interface,
    subcommand: Vec<String>,
    flags: Vec<String>,
    operands: Vec<String>,
    workdir: Option<PathBuf>,
    timeout: Option<Duration>,
    envs: Vec<(String, String)>,
    stdin: Option<PathBuf>,
    accept_flake_config: bool,
    local_only: bool,
    json: bool,
    impure: bool,
    raw: bool,
    offline: bool,
}

#[derive(Clone, Copy)]
enum Interface {
    Nix,
    EvalJobs,
}

impl Invocation {
    fn base(program: &str, subcommand: &str, accept_flake_config: bool) -> Invocation {
        Invocation {
            program: program.into(),
            interface: Interface::Nix,
            subcommand: subcommand.split_whitespace().map(str::to_string).collect(),
            flags: Vec::new(),
            operands: Vec::new(),
            workdir: None,
            timeout: None,
            envs: Vec::new(),
            stdin: None,
            accept_flake_config,
            local_only: false,
            json: false,
            impure: false,
            raw: false,
            offline: false,
        }
    }

    /// A nix subcommand on a flake installable. The flake's own nixConfig
    /// (the shared cache) applies.
    pub fn flake(subcommand: &str, installable: impl Into<String>) -> Invocation {
        Invocation::base("nix", subcommand, true).operand(installable)
    }

    /// A nix subcommand on `--expr`. No flake is named, so the shared cache
    /// applies only through [`Invocation::accepts_flake_config`], for
    /// expressions that getFlake a checkout.
    pub fn expr(subcommand: &str, expr: impl Into<String>) -> Invocation {
        let mut invocation = Invocation::base("nix", subcommand, false);
        invocation.flags.push("--expr".into());
        invocation.flags.push(expr.into());
        invocation
    }

    /// A nix subcommand over store paths or other non-evaluating operands.
    pub fn plain(subcommand: &str) -> Invocation {
        Invocation::base("nix", subcommand, false)
    }

    /// A non-`nix` frontend sharing the flag conventions: nix-store,
    /// nix-prefetch-url, and similar tools.
    pub fn tool(program: &str) -> Invocation {
        Invocation::base(program, "", false)
    }

    pub fn eval_jobs() -> Invocation {
        let mut invocation = Invocation::base("nix-eval-jobs", "", false);
        invocation.interface = Interface::EvalJobs;
        invocation
    }

    pub fn accepts_flake_config(mut self) -> Invocation {
        self.accept_flake_config = true;
        self
    }

    pub fn arg(mut self, arg: impl Into<String>) -> Invocation {
        self.flags.push(arg.into());
        self
    }

    pub fn args<I: IntoIterator<Item = S>, S: Into<String>>(mut self, args: I) -> Invocation {
        self.flags.extend(args.into_iter().map(Into::into));
        self
    }

    pub fn option(self, name: &str, value: impl Into<String>) -> Invocation {
        self.arg("--option").arg(name).arg(value)
    }

    /// A positional operand (installable, store path); operands render after
    /// every flag, so a trailing option can never bind to the wrong slot.
    pub fn operand(mut self, operand: impl Into<String>) -> Invocation {
        self.operands.push(operand.into());
        self
    }

    pub fn operands<I: IntoIterator<Item = S>, S: Into<String>>(
        mut self,
        operands: I,
    ) -> Invocation {
        self.operands.extend(operands.into_iter().map(Into::into));
        self
    }

    pub fn apply(self, expr: &str) -> Invocation {
        self.arg("--apply").arg(expr)
    }

    pub fn workdir(mut self, dir: impl Into<PathBuf>) -> Invocation {
        self.workdir = Some(dir.into());
        self
    }

    pub fn timeout(mut self, timeout: Duration) -> Invocation {
        self.timeout = Some(timeout);
        self
    }

    pub fn env(mut self, name: &str, value: impl Into<String>) -> Invocation {
        self.envs.push((name.into(), value.into()));
        self
    }

    /// Feed the command a file on stdin.
    pub fn stdin(mut self, path: impl Into<PathBuf>) -> Invocation {
        self.stdin = Some(path.into());
        self
    }

    /// Fold the route's placement in: store and eval-store for a Store
    /// route, the builders guard for the rest. A host route is refused, so
    /// no nix command can silently run locally when the caller meant the
    /// host. Each frontend gets the store spelling its interface accepts.
    pub fn route(mut self, route: &Route) -> Result<Invocation> {
        let mut carrier = Command::new(&self.program);
        match self.interface {
            Interface::Nix => route.configure_nix(&mut carrier)?,
            Interface::EvalJobs => route.configure_eval_jobs(&mut carrier)?,
        }
        self.flags.extend(
            carrier
                .get_args()
                .map(|arg| arg.to_string_lossy().into_owned()),
        );
        Ok(self)
    }

    /// Read only what is already local: no substituters, so a missing path
    /// is an answer rather than a download.
    pub fn local_only(mut self) -> Invocation {
        self.local_only = true;
        self
    }

    pub fn json(mut self) -> Invocation {
        self.json = true;
        self
    }

    pub fn impure(mut self) -> Invocation {
        self.impure = true;
        self
    }

    pub fn raw(mut self) -> Invocation {
        self.raw = true;
        self
    }

    pub fn offline(mut self) -> Invocation {
        self.offline = true;
        self
    }

    fn configured_command(&self) -> Result<Command> {
        let mut cmd = Command::new(&self.program);
        if let Some(dir) = &self.workdir {
            cmd.current_dir(dir);
        }
        for (name, value) in &self.envs {
            cmd.env(name, value);
        }
        if let Some(path) = &self.stdin {
            let file =
                std::fs::File::open(path).map_err(|e| crate::support::error::io(path, e))?;
            cmd.stdin(file);
        }
        cmd.args(&self.subcommand);
        cmd.args(&self.flags);
        if self.json {
            cmd.arg("--json");
        }
        if self.impure {
            cmd.arg("--impure");
        }
        if self.raw {
            cmd.arg("--raw");
        }
        if self.offline {
            cmd.arg("--offline");
        }
        if self.accept_flake_config {
            cmd.args(["--option", "accept-flake-config", "true"]);
        }
        if self.local_only {
            cmd.args(["--option", "substituters", ""]);
        }
        cmd.args(&self.operands);
        Ok(cmd)
    }

    pub fn command(&self) -> Result<Command> {
        if self.timeout.is_some() {
            return Err(Error::Failure(
                "a timed nix invocation cannot export an unbounded command".into(),
            ));
        }
        self.configured_command()
    }

    pub fn run_piped(
        &self,
        stdout: impl FnOnce(Box<dyn std::io::Read + Send>) -> Result<()> + Send,
        stderr: impl FnOnce(Box<dyn std::io::Read + Send>) -> Result<()> + Send,
    ) -> Result<crate::support::tools::Completion<std::process::ExitStatus>> {
        let mut command = self.configured_command()?;
        crate::support::tools::piped(
            &mut command,
            self.timeout.map(crate::support::tools::Timeout::new),
            |stream| stdout(Box::new(stream)),
            |stream| stderr(Box::new(stream)),
        )
    }

    /// Captured execution with a hook that receives the owned child process
    /// group. Background owners use the id to cancel and then join their
    /// worker.
    pub fn run_with_output_started(
        &self,
        configure: impl FnOnce(&mut Command),
        started: impl FnOnce(u32),
    ) -> Result<crate::support::tools::Completion<std::process::Output>> {
        let mut command = self.configured_command()?;
        configure(&mut command);
        let child = crate::support::tools::spawn(&mut command)?;
        started(child.id());
        let output = match self.timeout {
            Some(timeout) => {
                child.wait_with_output_timeout(crate::support::tools::Timeout::new(timeout))
            }
            None => child
                .wait_with_output()
                .map(crate::support::tools::Completion::Finished),
        };
        output.map_err(|error| {
            Error::Failure(format!(
                "waiting for {}: {error}",
                crate::support::tools::rendered(&command)
            ))
        })
    }

    pub fn checked_output(&self, context: &str) -> Result<Vec<u8>> {
        let mut command = self.configured_command()?;
        match self.timeout {
            Some(timeout) => crate::support::tools::checked_output_timeout(
                &mut command,
                context,
                crate::support::tools::Timeout::new(timeout),
            ),
            None => crate::support::tools::checked_output(&mut command, context),
        }
    }

    pub fn checked_text(&self, context: &str) -> Result<String> {
        let bytes = self.checked_output(context)?;
        Ok(String::from_utf8_lossy(&bytes).into_owned())
    }

    pub fn run_json(&self, context: &str) -> Result<Value> {
        let bytes = self.checked_output(context)?;
        serde_json::from_slice(&bytes).map_err(|source| Error::Json {
            path: format!("<{context}>").into(),
            source,
        })
    }

    /// Run and report the exit without capturing, for commands that stream
    /// to the terminal.
    pub fn status(&self) -> Result<CommandStatus> {
        let mut cmd = self.configured_command()?;
        let status = match self.timeout {
            Some(timeout) => match crate::support::tools::status_timeout(
                &mut cmd,
                crate::support::tools::Timeout::new(timeout),
            )? {
                crate::support::tools::Completion::Finished(status) => status,
                crate::support::tools::Completion::TimedOut(_) => {
                    return Err(Error::Failure(format!(
                        "{} timed out after {} seconds",
                        crate::support::tools::rendered(&cmd),
                        timeout.as_secs()
                    )));
                }
            },
            None => crate::support::tools::status(&mut cmd)?,
        };
        Ok(CommandStatus::from_exit(status))
    }

    /// Run captured, so nix's transfer chatter cannot fight the progress
    /// ticker for the terminal; the stderr tail comes back for the caller's
    /// failure message.
    pub fn captured_status(&self) -> Result<(CommandStatus, String)> {
        let mut cmd = self.configured_command()?;
        let output = self.output(&mut cmd)?;
        let tail = crate::support::error::tail(&String::from_utf8_lossy(&output.stderr), 300);
        Ok((CommandStatus::from_exit(output.status), tail))
    }

    /// An unchecked run for callers that parse failure output (a dry-run
    /// plan, a hash minted from a failing build). The reason names why the
    /// exit code is the caller's to judge: it explains the call site to a
    /// reader, so it belongs in the transcript only when asked for. Printed
    /// unconditionally it became the whole result of a failed run, since a
    /// note is often a log's last line.
    pub fn probe(&self, reason: &str) -> Result<Probe> {
        let mut cmd = self.configured_command()?;
        if crate::support::ui::verbosity() == crate::support::ui::Verbosity::Verbose {
            crate::support::ui::note(format!("  (probe: {reason})"));
        }
        let output = self.output(&mut cmd)?;
        Ok(Probe {
            status: CommandStatus::from_exit(output.status),
            stdout: output.stdout,
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
    }

    fn output(&self, cmd: &mut Command) -> Result<std::process::Output> {
        match self.timeout {
            Some(timeout) => match crate::support::tools::output_timeout(
                cmd,
                crate::support::tools::Timeout::new(timeout),
            )? {
                crate::support::tools::Completion::Finished(output) => Ok(output),
                crate::support::tools::Completion::TimedOut(_) => Err(Error::Failure(format!(
                    "{} timed out after {} seconds",
                    crate::support::tools::rendered(cmd),
                    timeout.as_secs()
                ))),
            },
            None => crate::support::tools::output(cmd),
        }
    }

    /// Build with `--print-out-paths` and return the paths, so no caller
    /// re-parses the output by hand.
    pub fn out_paths(self, context: &str) -> Result<Vec<PathBuf>> {
        let text = self.arg("--print-out-paths").checked_text(context)?;
        let paths: Vec<PathBuf> = text.split_whitespace().map(PathBuf::from).collect();
        if paths.is_empty() {
            return Err(Error::Failure(format!(
                "{context}: no output path reported"
            )));
        }
        Ok(paths)
    }
}

/// Format the checkout with the flake's own formatter.
pub fn fmt(repo: &std::path::Path) -> Result<()> {
    let status = Invocation::plain("fmt")
        .accepts_flake_config()
        .workdir(repo)
        .status()?;
    if !status.is_success() {
        return Err(Error::Failure("nix fmt failed".into()));
    }
    Ok(())
}

/// Evaluate any installable as JSON, optionally through `--apply`.
pub fn eval_installable(installable: &str, apply: Option<&str>) -> Result<Value> {
    let mut invocation = Invocation::flake("eval", installable).json();
    if let Some(expr) = apply {
        invocation = invocation.apply(expr);
    }
    invocation.run_json(&format!("eval of {installable}"))
}

/// Evaluate `legacyPackages.<system>.<attr>`, optionally through `--apply`.
pub fn eval(flake: &Flake<'_>, attr: &str, apply: Option<&str>) -> Result<Value> {
    eval_installable(&project_installable(flake.0, attr), apply)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::{canonical_webcs_apply, Invocation};

    #[test]
    fn a_timed_invocation_cannot_lose_its_deadline() {
        let error = Invocation::tool("true")
            .timeout(Duration::from_secs(1))
            .command()
            .unwrap_err()
            .to_string();
        assert!(error.contains("cannot export"), "{error}");
    }

    #[test]
    fn canonical_webc_filter_runs_in_nix() {
        let apply = canonical_webcs_apply("name: _: name");
        let expression = [
            "let ws = { \
             canonical.passthru.wasmer.packageKey = \"canonical\"; \
             alias.passthru.wasmer.packageKey = \"canonical\"; \
             legacy.passthru.wasmer = {}; \
             }; in (",
            &apply,
            ") ws",
        ]
        .concat();
        let value = Invocation::expr("eval", expression)
            .option("experimental-features", "nix-command")
            .args(["--store", "dummy://"])
            .json()
            .run_json("canonical webc filter")
            .unwrap();
        let entries = value.as_object().unwrap();
        assert_eq!(entries["canonical"], "canonical");
        assert_eq!(entries["legacy"], "legacy");
        assert!(!entries.contains_key("alias"));
    }
}
