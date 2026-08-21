//! Running an external tool: how it is echoed, how a failure reads, and what
//! to say when the tool is missing. Each command is packaged with the tools it
//! needs, so `nix run .#build` always has them; a bare shell may not, and a
//! plain ENOENT names neither what was missing nor where to get it.

use std::ffi::OsStr;
use std::process::{ChildStderr, ChildStdin, ChildStdout, Command, ExitStatus, Output};
use std::time::{Duration, Instant};

use crate::support::error::{Error, Result};
use crate::support::ui;

/// The subcommand as typed, so the message names the app that would have
/// carried the tool.
fn command_hint() -> String {
    crate::support::env::arg1().unwrap_or_else(|| "<command>".to_string())
}

fn spawn_failed(program: &OsStr, error: std::io::Error) -> Error {
    let program = program.to_string_lossy();
    if error.kind() != std::io::ErrorKind::NotFound {
        return Error::Failure(format!("could not run {program}: {error}"));
    }
    Error::Request(format!(
        "{program} is not on PATH; run this as `nix run .#{}`, which carries its own tools, or add {program} to your shell",
        command_hint()
    ))
}

/// A command as a shell line, for the log. Every command the tool runs is
/// echoed the same way, so a transcript reads as one thing.
pub fn rendered(cmd: &Command) -> String {
    std::iter::once(cmd.get_program())
        .chain(cmd.get_args())
        .map(|part| part.to_string_lossy().into_owned())
        .collect::<Vec<_>>()
        .join(" ")
}

/// The command echo is plumbing, not narration: it prints under -v, while
/// the default transcript carries the conceptual facts around it.
pub fn log(cmd: &Command) {
    if ui::verbosity() == ui::Verbosity::Verbose {
        ui::note(format!(
            "  {}",
            crate::support::terminal::command(format!("$ {}", rendered(cmd)))
        ));
    }
}

pub fn status(cmd: &mut Command) -> Result<std::process::ExitStatus> {
    cmd.status()
        .map_err(|error| spawn_failed(cmd.get_program(), error))
}

pub fn output(cmd: &mut Command) -> Result<Output> {
    cmd.output()
        .map_err(|error| spawn_failed(cmd.get_program(), error))
}

/// A child that is killed and reaped on drop unless ownership is explicitly
/// transferred with [`Child::detach`].
pub struct Child {
    inner: Option<std::process::Child>,
    command: String,
    started: Instant,
}

impl Child {
    fn inner(&mut self) -> &mut std::process::Child {
        self.inner.as_mut().expect("child was already reaped")
    }

    fn completed(&self, status: ExitStatus) {
        if ui::verbosity() == ui::Verbosity::Verbose {
            ui::note(format!(
                "  finished {} with {} in {}",
                self.command,
                status,
                crate::support::format::duration(self.started.elapsed().as_secs_f64())
            ));
        }
    }

    pub fn id(&self) -> u32 {
        self.inner.as_ref().expect("child was already reaped").id()
    }

    pub fn stdin_mut(&mut self) -> Option<&mut ChildStdin> {
        self.inner().stdin.as_mut()
    }

    pub fn take_stdin(&mut self) -> Option<ChildStdin> {
        self.inner().stdin.take()
    }

    pub fn take_stdout(&mut self) -> Option<ChildStdout> {
        self.inner().stdout.take()
    }

    pub fn take_stderr(&mut self) -> Option<ChildStderr> {
        self.inner().stderr.take()
    }

    pub fn kill(&mut self) -> std::io::Result<()> {
        self.inner().kill()
    }

    pub fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
        let status = self.inner().try_wait()?;
        if let Some(status) = status {
            self.completed(status);
            self.inner = None;
        }
        Ok(status)
    }

    pub fn wait(&mut self) -> std::io::Result<ExitStatus> {
        let status = self.inner().wait()?;
        self.completed(status);
        self.inner = None;
        Ok(status)
    }

    pub fn wait_with_output(mut self) -> std::io::Result<Output> {
        let inner = self.inner.take().expect("child was already reaped");
        let output = inner.wait_with_output()?;
        self.completed(output.status);
        Ok(output)
    }

    pub fn detach(mut self) {
        self.inner.take();
    }
}

impl Drop for Child {
    fn drop(&mut self) {
        let Some(mut child) = self.inner.take() else {
            return;
        };
        let _ = child.kill();
        if let Ok(status) = child.wait() {
            self.completed(status);
        }
    }
}

pub fn spawn(cmd: &mut Command) -> Result<Child> {
    log(cmd);
    let command = rendered(cmd);
    let child = cmd
        .spawn()
        .map_err(|error| spawn_failed(cmd.get_program(), error))?;
    Ok(Child {
        inner: Some(child),
        command,
        started: Instant::now(),
    })
}

/// How much of a failing tool's diagnostics reaches the caller's message.
const STDERR_TAIL: usize = 1500;

/// The end of a failing tool's diagnostics. Transfer chatter is dropped
/// first, so a nix error under hundreds of `copying path` lines survives
/// the tail.
pub fn diagnostics_tail(text: &str) -> String {
    let kept: String = text
        .lines()
        .filter(|line| !crate::support::nix::progress_noise(line))
        .fold(String::new(), |mut kept, line| {
            kept.push_str(line);
            kept.push('\n');
            kept
        });
    crate::support::error::tail(&kept, STDERR_TAIL)
}

/// Run to completion; a nonzero exit becomes a request error carrying the
/// context and the end of the tool's diagnostics (stderr, or stdout when the
/// tool reports there).
pub fn checked_output(cmd: &mut Command, context: &str) -> Result<Vec<u8>> {
    log(cmd);
    let output = output(cmd)?;
    if output.status.success() {
        return Ok(output.stdout);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let diagnostics = if stderr.trim().is_empty() {
        String::from_utf8_lossy(&output.stdout).into_owned()
    } else {
        stderr.into_owned()
    };
    let detail = diagnostics_tail(&diagnostics);
    if detail.is_empty() {
        Err(Error::Failure(format!(
            "{context}: {} failed with {}",
            rendered(cmd),
            output.status
        )))
    } else {
        Err(Error::Failure(format!("{context}: {detail}")))
    }
}

/// Run to completion streaming to the terminal; a nonzero exit becomes an
/// error naming the context and the rendered command.
pub fn checked_status(cmd: &mut Command, context: &str) -> Result<()> {
    log(cmd);
    let status = status(cmd)?;
    if status.success() {
        Ok(())
    } else {
        Err(Error::Failure(format!(
            "{context}: {} exited {status}",
            rendered(cmd)
        )))
    }
}

pub fn checked_text(cmd: &mut Command, context: &str) -> Result<String> {
    let bytes = checked_output(cmd, context)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

pub fn timed_command(program: &str, timeout: Duration) -> Command {
    let mut command = Command::new("timeout");
    // Without --foreground, timeout puts itself and the command in a new
    // process group, so a cancel or sweep that signals the payload's group
    // never reaches the command and it orphans. --foreground keeps it in the
    // payload's group.
    command
        .args(["--foreground", "--signal=TERM", "--kill-after=30"])
        .arg(timeout.as_secs().to_string())
        .arg(program);
    command
}

pub fn utf8_suffix(text: &str, max_bytes: usize) -> &str {
    let mut start = text.len().saturating_sub(max_bytes);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}
