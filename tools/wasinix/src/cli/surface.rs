use clap::{CommandFactory, FromArgMatches};

use crate::support::error::{Error, Result};

use super::Cli;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Surface {
    Terminal,
    Comment,
}

fn clap_error(error: clap::Error) -> Error {
    let rendered = error.to_string();
    Error::Request(
        rendered
            .strip_prefix("error: ")
            .unwrap_or(&rendered)
            .to_string(),
    )
}

fn command_line_value(matches: &clap::ArgMatches, id: &str) -> bool {
    matches.ids().any(|found| found.as_str() == id)
        && matches.value_source(id) == Some(clap::parser::ValueSource::CommandLine)
}

fn terminal_only(matches: &clap::ArgMatches, ids: &[&str]) -> Result<()> {
    if let Some(id) = ids.iter().find(|id| command_line_value(matches, id)) {
        return Err(Error::Request(format!(
            "--{} is terminal only",
            id.replace('_', "-")
        )));
    }
    Ok(())
}

pub(crate) fn parse_comment(words: &[String]) -> Result<Cli> {
    let mut command = Cli::command();
    let matches = command
        .try_get_matches_from_mut(
            std::iter::once("wasinix").chain(words.iter().map(String::as_str)),
        )
        .map_err(clap_error)?;
    terminal_only(&matches, &["verbose", "quiet", "color"])?;
    let (name, args) = matches
        .subcommand()
        .ok_or_else(|| Error::Request("comment names no command".into()))?;
    match name {
        "build" | "spot" | "diff" => terminal_only(
            args,
            &[
                "on",
                "json",
                "run_dir",
                "junit_out",
                "push_cache",
                "inputs_only",
                "plan",
            ],
        )?,
        "bisect" => {
            terminal_only(args, &["run_dir"])?;
        }
        "ci" => return Err(Error::Request("ci is CI only".into())),
        _ => return Err(Error::Request(format!("{name} is terminal only"))),
    }
    Cli::from_arg_matches(&matches).map_err(clap_error)
}
