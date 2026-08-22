//! Running an external tool: how it is echoed, how a failure reads, and what
//! to say when the tool is missing. Each command is packaged with the tools it
//! needs, so `nix run .#build` always has them; a bare shell may not, and a
//! plain ENOENT names neither what was missing nor where to get it.

use std::ffi::OsStr;
use std::process::{ChildStderr, ChildStdin, ChildStdout, Command, ExitStatus, Output};
use std::sync::mpsc;
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
fn log(cmd: &Command) {
    if ui::verbosity() == ui::Verbosity::Verbose {
        ui::note(format!(
            "  {}",
            crate::support::terminal::command(format!("$ {}", rendered(cmd)))
        ));
    }
}

fn started(cmd: &Command) -> (String, Instant) {
    log(cmd);
    (rendered(cmd), Instant::now())
}

fn completed(command: &str, started: Instant, status: ExitStatus) {
    if ui::verbosity() == ui::Verbosity::Verbose {
        ui::note(format!(
            "  finished {command} with {status} in {}",
            crate::support::format::duration(started.elapsed().as_secs_f64())
        ));
    }
}

pub fn status(cmd: &mut Command) -> Result<std::process::ExitStatus> {
    spawn(cmd)?
        .wait()
        .map_err(|error| Error::Failure(format!("waiting for {}: {error}", rendered(cmd))))
}

pub fn output(cmd: &mut Command) -> Result<Output> {
    cmd.stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    spawn(cmd)?
        .wait_with_output()
        .map_err(|error| Error::Failure(format!("waiting for {}: {error}", rendered(cmd))))
}

/// A child that is killed and reaped on drop unless ownership is explicitly
/// transferred with [`Child::detach`].
pub struct Child {
    inner: Option<std::process::Child>,
    command: String,
    started: Instant,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Completion<T> {
    Finished(T),
    TimedOut(T),
}

pub struct Piped<T> {
    pub status: ExitStatus,
    pub stdout: T,
}

impl<T> Completion<T> {
    pub fn value(self) -> T {
        match self {
            Completion::Finished(value) | Completion::TimedOut(value) => value,
        }
    }
}

#[derive(Clone, Copy)]
pub struct Timeout {
    after: Duration,
    terminate_after: Duration,
}

impl Timeout {
    pub fn new(after: Duration) -> Timeout {
        Timeout {
            after,
            terminate_after: Duration::from_secs(30),
        }
    }

    #[cfg(test)]
    pub fn with_grace(after: Duration, terminate_after: Duration) -> Timeout {
        Timeout {
            after,
            terminate_after,
        }
    }
}

#[cfg(not(unix))]
fn force_kill(child: &mut std::process::Child) -> std::io::Result<()> {
    child.kill()
}

#[cfg(unix)]
fn force_kill(child: &mut std::process::Child) -> std::io::Result<()> {
    crate::support::process::signal_group(child.id(), libc::SIGKILL)
}

fn wait_deadline<T: Send + 'static>(
    child: std::process::Child,
    timeout: Timeout,
    wait: impl FnOnce(std::process::Child) -> std::io::Result<T> + Send + 'static,
) -> std::io::Result<Completion<T>> {
    let pid = child.id();
    let (sender, receiver) = mpsc::sync_channel(1);
    let waiter = std::thread::spawn(move || {
        let _ = sender.send(wait(child));
    });
    let completion = match receiver.recv_timeout(timeout.after) {
        Ok(result) => Completion::Finished(result?),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            return Err(std::io::Error::other("child waiter stopped unexpectedly"));
        }
        Err(mpsc::RecvTimeoutError::Timeout) => {
            #[cfg(unix)]
            crate::support::process::signal_group(pid, libc::SIGTERM)?;
            match receiver.recv_timeout(timeout.terminate_after) {
                Ok(result) => Completion::TimedOut(result?),
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    return Err(std::io::Error::other("child waiter stopped unexpectedly"));
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    #[cfg(unix)]
                    crate::support::process::signal_group(pid, libc::SIGKILL)?;
                    #[cfg(not(unix))]
                    return Err(std::io::Error::other(
                        "child did not exit after timeout termination",
                    ));
                    Completion::TimedOut(receiver.recv().map_err(|_| {
                        std::io::Error::other("child waiter stopped unexpectedly")
                    })??)
                }
            }
        }
    };
    waiter
        .join()
        .map_err(|_| std::io::Error::other("child waiter panicked"))?;
    Ok(completion)
}

impl Child {
    fn inner(&mut self) -> &mut std::process::Child {
        self.inner.as_mut().expect("child was already reaped")
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
        force_kill(self.inner())
    }

    pub fn try_wait(&mut self) -> std::io::Result<Option<ExitStatus>> {
        let status = self.inner().try_wait()?;
        if let Some(status) = status {
            completed(&self.command, self.started, status);
            self.inner = None;
        }
        Ok(status)
    }

    pub fn wait(&mut self) -> std::io::Result<ExitStatus> {
        let status = self.inner().wait()?;
        completed(&self.command, self.started, status);
        self.inner = None;
        Ok(status)
    }

    pub fn wait_with_output(mut self) -> std::io::Result<Output> {
        let inner = self.inner.take().expect("child was already reaped");
        let output = inner.wait_with_output()?;
        completed(&self.command, self.started, output.status);
        Ok(output)
    }

    pub fn wait_timeout(mut self, timeout: Timeout) -> std::io::Result<Completion<ExitStatus>> {
        let inner = self.inner.take().expect("child was already reaped");
        let completion = wait_deadline(inner, timeout, |mut child| child.wait())?;
        completed(&self.command, self.started, *match &completion {
            Completion::Finished(status) | Completion::TimedOut(status) => status,
        });
        Ok(completion)
    }

    pub fn wait_with_output_timeout(
        mut self,
        timeout: Timeout,
    ) -> std::io::Result<Completion<Output>> {
        let inner = self.inner.take().expect("child was already reaped");
        let completion = wait_deadline(inner, timeout, |child| child.wait_with_output())?;
        completed(
            &self.command,
            self.started,
            match &completion {
                Completion::Finished(output) | Completion::TimedOut(output) => output.status,
            },
        );
        Ok(completion)
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
        let _ = force_kill(&mut child);
        if let Ok(status) = child.wait() {
            completed(&self.command, self.started, status);
        }
    }
}

pub fn spawn(cmd: &mut Command) -> Result<Child> {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        cmd.process_group(0);
    }
    let (command, started) = started(cmd);
    let child = cmd
        .spawn()
        .map_err(|error| spawn_failed(cmd.get_program(), error))?;
    Ok(Child {
        inner: Some(child),
        command,
        started,
    })
}

pub struct PipeReaders(Vec<std::thread::JoinHandle<Result<()>>>);

impl PipeReaders {
    pub fn join(self, cmd: &Command) -> Result<()> {
        let mut failure = None;
        for reader in self.0 {
            let result = reader
                .join()
                .map_err(|_| {
                    Error::Failure(format!("reading output from {} panicked", rendered(cmd)))
                })
                .and_then(|result| result);
            if failure.is_none() {
                failure = result.err();
            }
        }
        if let Some(error) = failure {
            return Err(error);
        }
        Ok(())
    }
}

pub fn spawn_piped(
    cmd: &mut Command,
    stdout: impl FnOnce(ChildStdout) -> Result<()> + Send + 'static,
    stderr: impl FnOnce(ChildStderr) -> Result<()> + Send + 'static,
) -> Result<(Child, PipeReaders)> {
    cmd.stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = spawn(cmd)?;
    let child_stdout = child.take_stdout().expect("stdout was piped");
    let child_stderr = child.take_stderr().expect("stderr was piped");
    let readers = PipeReaders(vec![
        std::thread::spawn(move || stdout(child_stdout)),
        std::thread::spawn(move || stderr(child_stderr)),
    ]);
    Ok((child, readers))
}

pub fn piped<T>(
    cmd: &mut Command,
    timeout: Option<Timeout>,
    stdout: impl FnOnce(ChildStdout) -> Result<T> + Send,
    stderr: impl FnOnce(ChildStderr) -> Result<()> + Send,
) -> Result<Completion<Piped<T>>>
where
    T: Send,
{
    cmd.stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = spawn(cmd)?;
    let child_stdout = child.take_stdout().expect("stdout was piped");
    let child_stderr = child.take_stderr().expect("stderr was piped");
    std::thread::scope(|scope| {
        let stdout_reader = scope.spawn(move || stdout(child_stdout));
        let stderr_reader = scope.spawn(move || stderr(child_stderr));
        let completion = match timeout {
            Some(timeout) => child.wait_timeout(timeout),
            None => child.wait().map(Completion::Finished),
        }
        .map_err(|error| Error::Failure(format!("waiting for {}: {error}", rendered(cmd))))?;
        let stdout = stdout_reader
            .join()
            .map_err(|_| {
                Error::Failure(format!("reading stdout from {} panicked", rendered(cmd)))
            })??;
        stderr_reader
            .join()
            .map_err(|_| {
                Error::Failure(format!("reading stderr from {} panicked", rendered(cmd)))
            })??;
        Ok(match completion {
            Completion::Finished(status) => Completion::Finished(Piped { status, stdout }),
            Completion::TimedOut(status) => Completion::TimedOut(Piped { status, stdout }),
        })
    })
}

pub fn output_timeout(cmd: &mut Command, timeout: Timeout) -> Result<Completion<Output>> {
    cmd.stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    spawn(cmd)?
        .wait_with_output_timeout(timeout)
        .map_err(|error| Error::Failure(format!("waiting for {}: {error}", rendered(cmd))))
}

pub fn status_timeout(cmd: &mut Command, timeout: Timeout) -> Result<Completion<ExitStatus>> {
    spawn(cmd)?
        .wait_timeout(timeout)
        .map_err(|error| Error::Failure(format!("waiting for {}: {error}", rendered(cmd))))
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
    let output = output(cmd)?;
    check_output(cmd, context, output)
}

pub fn checked_output_timeout(
    cmd: &mut Command,
    context: &str,
    timeout: Timeout,
) -> Result<Vec<u8>> {
    match output_timeout(cmd, timeout)? {
        Completion::Finished(output) => check_output(cmd, context, output),
        Completion::TimedOut(_) => Err(Error::Failure(format!(
            "{context}: {} timed out after {} seconds",
            rendered(cmd),
            timeout.after.as_secs()
        ))),
    }
}

pub(crate) fn check_output(cmd: &Command, context: &str, output: Output) -> Result<Vec<u8>> {
    if output.status.success() {
        return Ok(output.stdout);
    }
    let stderr = String::from_utf8_lossy(&output.stderr);
    let (stream, diagnostics) = if stderr.trim().is_empty() {
        (
            "stdout",
            String::from_utf8_lossy(&output.stdout).into_owned(),
        )
    } else {
        ("stderr", stderr.into_owned())
    };
    let detail = diagnostics_tail(&diagnostics);
    if detail.is_empty() {
        Err(Error::Failure(format!(
            "{context}: {} failed with {}",
            rendered(cmd),
            output.status
        )))
    } else {
        Err(Error::Failure(format!("{context} ({stream}): {detail}")))
    }
}

/// Run to completion streaming to the terminal; a nonzero exit becomes an
/// error naming the context and the rendered command.
pub fn checked_status(cmd: &mut Command, context: &str) -> Result<()> {
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

#[cfg(test)]
pub fn checked_text(cmd: &mut Command, context: &str) -> Result<String> {
    let bytes = checked_output(cmd, context)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

pub fn checked_text_timeout(
    cmd: &mut Command,
    context: &str,
    timeout: Timeout,
) -> Result<String> {
    let bytes = checked_output_timeout(cmd, context, timeout)?;
    Ok(String::from_utf8_lossy(&bytes).into_owned())
}

pub fn utf8_suffix(text: &str, max_bytes: usize) -> &str {
    let mut start = text.len().saturating_sub(max_bytes);
    while !text.is_char_boundary(start) {
        start += 1;
    }
    &text[start..]
}
