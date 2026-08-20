//! The presentation edge: the only module that prints for humans. Results go
//! to stdout, everything else to stderr, and one logical block never straddles
//! the two.

use std::sync::atomic::{AtomicU8, Ordering};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Verbosity {
    Quiet,
    Normal,
    Verbose,
}

static VERBOSITY: AtomicU8 = AtomicU8::new(1);
static JSON: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn json_mode() -> bool {
    JSON.load(Ordering::Relaxed)
}

/// The one `--json` declaration. Parsing the flag flips the process into
/// json mode on the spot, so a failure at any later point still keeps the
/// promise of exactly one document on stdout. Emission goes through
/// [`emit`], which demands this value: an arm without a JsonArg cannot
/// print a document.
#[derive(Clone, Copy, Debug, Default)]
pub struct JsonArg {
    json: bool,
}

impl JsonArg {
    pub fn wants(&self) -> bool {
        self.json
    }
}

impl clap::FromArgMatches for JsonArg {
    fn from_arg_matches(matches: &clap::ArgMatches) -> std::result::Result<JsonArg, clap::Error> {
        let json = matches.get_flag("json");
        if json {
            JSON.store(true, Ordering::Relaxed);
        }
        Ok(JsonArg { json })
    }

    fn update_from_arg_matches(
        &mut self,
        matches: &clap::ArgMatches,
    ) -> std::result::Result<(), clap::Error> {
        *self = Self::from_arg_matches(matches)?;
        Ok(())
    }
}

impl clap::Args for JsonArg {
    fn augment_args(cmd: clap::Command) -> clap::Command {
        cmd.arg(
            clap::Arg::new("json")
                .long("json")
                .action(clap::ArgAction::SetTrue)
                .help("Machine output: one schema document on stdout"),
        )
    }

    fn augment_args_for_update(cmd: clap::Command) -> clap::Command {
        Self::augment_args(cmd)
    }
}

/// The command's one answer: the schema document on stdout under --json,
/// the human rendering otherwise.
pub fn emit<T: crate::support::schema::Document + serde::Serialize>(
    json: &JsonArg,
    document: &T,
    human: impl FnOnce(&T),
) -> crate::support::error::Result<()> {
    if json.json {
        crate::support::json::print(&crate::support::schema::to_value(document)?)
    } else {
        human(document);
        Ok(())
    }
}

/// [`emit`] for a document already enveloped on disk (a report read back).
pub fn emit_value(
    json: &JsonArg,
    value: &serde_json::Value,
    human: impl FnOnce(),
) -> crate::support::error::Result<()> {
    if json.json {
        crate::support::json::print(value)
    } else {
        human();
        Ok(())
    }
}

/// The top-level error path: under a declared --json, stdout still carries
/// exactly one document, so the error becomes one; the exit code is
/// unchanged either way.
pub fn report_error(error: &crate::support::error::Error) {
    if json_mode() {
        let _ = crate::support::json::print(&serde_json::json!({
            "schema": 1,
            "kind": "error",
            "code": error.status().code(),
            "message": error.to_string(),
        }));
    }
    self::error(error);
}

pub fn set_verbosity(verbosity: Verbosity) {
    let value = match verbosity {
        Verbosity::Quiet => 0,
        Verbosity::Normal => 1,
        Verbosity::Verbose => 2,
    };
    VERBOSITY.store(value, Ordering::Relaxed);
}

pub fn verbosity() -> Verbosity {
    match VERBOSITY.load(Ordering::Relaxed) {
        0 => Verbosity::Quiet,
        2 => Verbosity::Verbose,
        _ => Verbosity::Normal,
    }
}

/// `key: value` on stderr; facts about a run in flight.
pub fn fact(key: &str, value: impl std::fmt::Display) {
    if verbosity() != Verbosity::Quiet {
        eprintln!("{key}: {value}");
    }
}

/// A result line on stdout; part of the command's answer.
pub fn result(line: impl std::fmt::Display) {
    println!("{line}");
}

/// Preformatted result text (tables, fetched blocks) on stdout, verbatim.
pub fn output(text: impl std::fmt::Display) {
    print!("{text}");
}

/// A progress note on stderr; silenced by --quiet.
pub fn note(line: impl std::fmt::Display) {
    if verbosity() != Verbosity::Quiet {
        eprintln!("{line}");
    }
}

/// Raw evidence passed through to stderr; the caller decides when.
pub fn raw(text: impl std::fmt::Display) {
    eprint!("{text}");
}

pub fn warning(text: impl std::fmt::Display) {
    eprintln!("warning: {text}");
}

pub fn error(text: impl std::fmt::Display) {
    eprintln!(
        "{}",
        crate::support::terminal::error(format!("error: {text}"))
    );
}

/// Facts joined with the shared separator: `5213 jobs · 39 failed · 3h 06m`.
pub fn counts(parts: &[String]) -> String {
    parts.join(" · ")
}
