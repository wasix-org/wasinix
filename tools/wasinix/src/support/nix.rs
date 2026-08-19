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

/// The nix config block workflows install, from the same constants the
/// binary trusts. min-free/max-free (10 GiB floor, 50 GiB target, in bytes)
/// let the daemon garbage-collect mid-build instead of filling the runner
/// disk; a collected path re-substitutes from the cache.
pub fn nix_config() -> String {
    format!(
        "extra-substituters = {CACHE_SUBSTITUTER}\n\
         extra-trusted-public-keys = {CACHE_PUBLIC_KEY}\n\
         trusted-users = root runner\n\
         min-free = 10737418240\n\
         max-free = 53687091200\n"
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

impl Invocation {
    fn base(program: &str, subcommand: &str, accept_flake_config: bool) -> Invocation {
        Invocation {
            program: program.into(),
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
    /// nix-eval-jobs, nix-prefetch-url.
    pub fn tool(program: &str) -> Invocation {
        Invocation::base(program, "", false)
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
    /// host. nix-eval-jobs takes its own store spelling.
    pub fn route(mut self, route: &Route) -> Result<Invocation> {
        let mut carrier = Command::new(&self.program);
        if self.program == "nix-eval-jobs" {
            route.configure_eval_jobs(&mut carrier)?;
        } else {
            route.configure_nix(&mut carrier)?;
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

    pub fn command(&self) -> Result<Command> {
        let mut cmd = match self.timeout {
            Some(timeout) => crate::support::tools::timed_command(&self.program, timeout),
            None => Command::new(&self.program),
        };
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

    pub fn checked_output(&self, context: &str) -> Result<Vec<u8>> {
        crate::support::tools::checked_output(&mut self.command()?, context)
    }

    pub fn checked_text(&self, context: &str) -> Result<String> {
        crate::support::tools::checked_text(&mut self.command()?, context)
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
        let mut cmd = self.command()?;
        crate::support::tools::log(&cmd);
        Ok(CommandStatus::from_exit(crate::support::tools::status(
            &mut cmd,
        )?))
    }

    /// Run captured, so nix's transfer chatter cannot fight the progress
    /// ticker for the terminal; the stderr tail comes back for the caller's
    /// failure message.
    pub fn captured_status(&self) -> Result<(CommandStatus, String)> {
        let mut cmd = self.command()?;
        crate::support::tools::log(&cmd);
        let output = crate::support::tools::output(&mut cmd)?;
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
        let mut cmd = self.command()?;
        crate::support::tools::log(&cmd);
        if crate::support::ui::verbosity() == crate::support::ui::Verbosity::Verbose {
            crate::support::ui::note(format!("  (probe: {reason})"));
        }
        let output = crate::support::tools::output(&mut cmd)?;
        Ok(Probe {
            status: CommandStatus::from_exit(output.status),
            stdout: output.stdout,
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        })
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
    eval_installable(&format!("{}#legacyPackages.{SYSTEM}.{attr}", flake.0), apply)
}

#[cfg(test)]
mod tests {
    use super::{canonical_webcs_apply, Invocation};

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
