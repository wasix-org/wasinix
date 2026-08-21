//! Every git call runs through this module and names the repository
//! explicitly, so no code path depends on the process working directory;
//! `repo_root` is the single, named cwd-discovery exception. Exit codes that carry an answer
//! (is-ancestor, staged-diff) are read three ways, never conflated with
//! failure.

use std::path::Path;
use std::process::Command;

use crate::support::error::{Result, request_error};

fn command(repo: &Path, args: &[&str]) -> Command {
    let mut cmd = Command::new("git");
    cmd.arg("-C").arg(repo).args(args);
    cmd
}

fn failed(output: &std::process::Output) -> String {
    String::from_utf8_lossy(if output.stderr.is_empty() {
        &output.stdout
    } else {
        &output.stderr
    })
    .trim()
    .to_string()
}

/// Raw stdout. Patches are newline-sensitive, so nothing is trimmed here.
pub fn git_raw(repo: &Path, args: &[&str]) -> Result<String> {
    let output = crate::support::tools::output(&mut command(repo, args))?;
    if !output.status.success() {
        return request_error(failed(&output));
    }
    Ok(String::from_utf8_lossy(&output.stdout).to_string())
}

/// Trimmed stdout, for the callers reading a single value back.
pub fn git(repo: &Path, args: &[&str]) -> Result<String> {
    Ok(git_raw(repo, args)?.trim_end().to_string())
}

/// `git` with the command echoed to the transcript, for calls whose effect
/// the operator should see.
pub fn git_logged(repo: &Path, args: &[&str]) -> Result<String> {
    let mut cmd = command(repo, args);
    let output = crate::support::tools::output(&mut cmd)?;
    if !output.status.success() {
        return request_error(failed(&output));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_string())
}

/// `git` fed on stdin, for apply and friends; newline-exact.
pub fn git_stdin(repo: &Path, args: &[&str], input: &[u8]) -> Result<()> {
    use std::io::Write;
    let mut cmd = command(repo, args);
    cmd.stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped());
    let mut child = crate::support::tools::spawn(&mut cmd)?;
    child
        .stdin_mut()
        .expect("stdin was piped")
        .write_all(input)
        .map_err(|e| crate::support::error::io(repo, e))?;
    let output = child
        .wait_with_output()
        .map_err(|e| crate::support::error::io(repo, e))?;
    if !output.status.success() {
        return request_error(format!(
            "git {} failed: {}",
            args.join(" "),
            failed(&output)
        ));
    }
    Ok(())
}

/// A repository-less git call (clone, --version): logged, and named Global
/// so the -C rule stays auditable.
pub fn git_global(args: &[&str]) -> Result<String> {
    let mut cmd = Command::new("git");
    cmd.args(args);
    let output = crate::support::tools::output(&mut cmd)?;
    if !output.status.success() {
        return request_error(failed(&output));
    }
    Ok(String::from_utf8_lossy(&output.stdout)
        .trim_end()
        .to_string())
}

/// The checkout being worked on. `nix run` puts the caller in the store, but
/// the files a command reads and rewrites are in the working tree. The one
/// call allowed to read the process cwd.
pub fn repo_root() -> Result<std::path::PathBuf> {
    let mut cmd = Command::new("git");
    cmd.args(["rev-parse", "--show-toplevel"]);
    let output = crate::support::tools::output(&mut cmd)?;
    if !output.status.success() {
        return request_error("this must run from a git checkout");
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().into())
}

pub fn resolve_rev(repo: &Path, reference: &str) -> Result<crate::support::atoms::Rev> {
    let rev = git(
        repo,
        &["rev-parse", "--verify", &format!("{reference}^{{commit}}")],
    )?;
    crate::support::atoms::Rev::parse(&rev)
}

/// Whether `rev` is already contained in `reference`'s history. Exit 1 means
/// no; anything else means git could not answer, which the caller must not
/// mistake for either answer.
pub fn is_ancestor(repo: &Path, rev: &str, reference: &str) -> Result<bool> {
    let output = crate::support::tools::output(&mut command(
        repo,
        &["merge-base", "--is-ancestor", rev, reference],
    ))?;
    match output.status.code() {
        Some(0) => Ok(true),
        Some(1) => Ok(false),
        _ => request_error(format!(
            "git merge-base --is-ancestor {rev} {reference} failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )),
    }
}

/// What a commit stages: everything dirty, or exactly the named paths.
pub enum Stage<'a> {
    All,
    Paths(&'a [&'a str]),
}

/// The committer a mutation's commits carry; without one, the ambient git
/// config applies (a human running locally).
pub struct Identity<'a> {
    pub name: &'a str,
    pub email: &'a str,
}

pub fn commit(
    repo: &Path,
    stage: Stage<'_>,
    message: &str,
    identity: Option<&Identity<'_>>,
) -> Result<bool> {
    let add: Vec<&str> = match stage {
        Stage::All => vec!["add", "-A"],
        Stage::Paths(paths) => {
            let mut add = vec!["add", "--"];
            add.extend_from_slice(paths);
            add
        }
    };
    crate::support::tools::checked_status(&mut command(repo, &add), "git add")?;

    // Exit 1 from a --quiet diff is an answer (something is staged), not a
    // failure.
    let mut diff = command(repo, &["diff", "--cached", "--quiet"]);
    match crate::support::tools::status(&mut diff)?.code() {
        Some(0) => return Ok(false),
        Some(1) => {}
        code => return request_error(format!("git diff exited {}", code.unwrap_or(1))),
    }

    let mut args: Vec<String> = Vec::new();
    if let Some(identity) = identity {
        args.push("-c".into());
        args.push(format!("user.name={}", identity.name));
        args.push("-c".into());
        args.push(format!("user.email={}", identity.email));
    }
    args.extend(["commit".into(), "-m".into(), message.to_string()]);
    let arg_refs: Vec<&str> = args.iter().map(String::as_str).collect();
    crate::support::tools::checked_status(&mut command(repo, &arg_refs), "git commit")?;
    crate::support::ui::fact("committed", message);
    Ok(true)
}
