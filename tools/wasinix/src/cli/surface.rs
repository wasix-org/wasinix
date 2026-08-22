use clap::{CommandFactory, FromArgMatches};

use crate::github::sanitize::Markdown;
use crate::support::error::{Error, Result};

use super::Cli;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Surface {
    Terminal,
    Comment,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Availability {
    Shared,
    Terminal,
    Comment,
    Ci,
}

struct CommandPolicy {
    name: &'static str,
    availability: Availability,
}

struct LeafPolicy {
    path: &'static [&'static str],
    #[cfg(test)]
    shared_args: &'static [&'static str],
    terminal_args: &'static [&'static str],
    comment_args: &'static [&'static str],
}

const COMMANDS: &[CommandPolicy] = &[
    CommandPolicy {
        name: "build",
        availability: Availability::Shared,
    },
    CommandPolicy {
        name: "spot",
        availability: Availability::Shared,
    },
    CommandPolicy {
        name: "diff",
        availability: Availability::Shared,
    },
    CommandPolicy {
        name: "bisect",
        availability: Availability::Shared,
    },
    CommandPolicy {
        name: "jobs",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "doctor",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "timings",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "cache",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "run",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "cargo",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "wasmer",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "python",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "publish",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "preview",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "serve",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "update",
        availability: Availability::Shared,
    },
    CommandPolicy {
        name: "versions",
        availability: Availability::Shared,
    },
    CommandPolicy {
        name: "remote",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "ci",
        availability: Availability::Ci,
    },
    CommandPolicy {
        name: "completions",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "regenerate",
        availability: Availability::Comment,
    },
    CommandPolicy {
        name: "fmt",
        availability: Availability::Comment,
    },
    CommandPolicy {
        name: "help",
        availability: Availability::Shared,
    },
];

const VERSION_COMMANDS: &[CommandPolicy] = &[
    CommandPolicy {
        name: "add",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "import",
        availability: Availability::Terminal,
    },
    CommandPolicy {
        name: "bump",
        availability: Availability::Shared,
    },
];

const ROOT_TERMINAL_ARGS: &[&str] = &["verbose", "quiet", "color"];

#[cfg(test)]
const MUTATION_EFFECTS: &[&str] = &[
    "commit",
    "pr",
    "branch",
    "repository",
    "base",
    "fork",
    "json",
];

const LEAVES: &[LeafPolicy] = &[
    LeafPolicy {
        path: &["build"],
        #[cfg(test)]
        shared_args: &[
            "selectors",
            "enabled_tags",
            "at",
            "overrides",
            "from_pr",
            "blocked",
            "plan",
        ],
        terminal_args: &[
            "on",
            "json",
            "run_dir",
            "junit_out",
            "push_cache",
            "inputs_only",
        ],
        comment_args: &[],
    },
    LeafPolicy {
        path: &["spot"],
        #[cfg(test)]
        shared_args: &[
            "selectors",
            "enabled_tags",
            "at",
            "overrides",
            "from_pr",
            "base",
            "from_source",
            "target_only",
            "blocked",
            "plan",
        ],
        terminal_args: &[
            "on",
            "json",
            "run_dir",
            "junit_out",
            "push_cache",
            "inputs_only",
        ],
        comment_args: &[],
    },
    LeafPolicy {
        path: &["diff"],
        #[cfg(test)]
        shared_args: &["content_diff", "blocked", "plan", "words"],
        terminal_args: &["json", "run_dir", "junit_out", "push_cache", "inputs_only"],
        comment_args: &[],
    },
    LeafPolicy {
        path: &["bisect"],
        #[cfg(test)]
        shared_args: &[
            "target",
            "good",
            "bad",
            "first_parent",
            "reverse",
            "blocked",
            "command",
        ],
        terminal_args: &["run_dir"],
        comment_args: &[],
    },
    LeafPolicy {
        path: &["update"],
        #[cfg(test)]
        shared_args: &["targets", "all"],
        terminal_args: &[
            "expect",
            "commit",
            "pr",
            "branch",
            "repository",
            "base",
            "fork",
            "json",
        ],
        comment_args: &[],
    },
    LeafPolicy {
        path: &["versions", "bump"],
        #[cfg(test)]
        shared_args: &["specs", "all_versions"],
        terminal_args: &[
            "changed_from",
            "commit",
            "pr",
            "branch",
            "repository",
            "base",
            "fork",
            "json",
        ],
        comment_args: &["changed"],
    },
    LeafPolicy {
        path: &["regenerate"],
        #[cfg(test)]
        shared_args: &[],
        terminal_args: &[],
        comment_args: &[],
    },
    LeafPolicy {
        path: &["fmt"],
        #[cfg(test)]
        shared_args: &[],
        terminal_args: &[],
        comment_args: &[],
    },
    LeafPolicy {
        path: &["help"],
        #[cfg(test)]
        shared_args: &[],
        terminal_args: &[],
        comment_args: &[],
    },
];

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

fn policy<'a>(policies: &'a [CommandPolicy], name: &str) -> Result<&'a CommandPolicy> {
    policies
        .iter()
        .find(|policy| policy.name == name)
        .ok_or_else(|| Error::Request(format!("{name} has no command-surface policy")))
}

fn reject_unavailable(policy: &CommandPolicy, path: &str) -> Result<()> {
    match policy.availability {
        Availability::Shared | Availability::Comment => Ok(()),
        Availability::Terminal => Err(Error::Request(format!("{path} is terminal only"))),
        Availability::Ci => Err(Error::Request(format!("{path} is CI only"))),
    }
}

fn annotate_about(command: clap::Command, label: &'static str) -> clap::Command {
    let about = command
        .get_about()
        .map(ToString::to_string)
        .unwrap_or_default();
    command.hide(false).about(format!("{about} ({label} only)"))
}

fn annotate_arg(command: clap::Command, id: &'static str) -> clap::Command {
    command.mut_arg(id, |arg| {
        let help = arg.get_help().map(ToString::to_string).unwrap_or_default();
        arg.help(format!("{help} (comment only)"))
    })
}

fn annotate_path(
    command: clap::Command,
    path: &[&'static str],
    args: &[&'static str],
) -> clap::Command {
    command.mut_subcommand(path[0], |mut child| {
        if path.len() == 1 {
            for id in args {
                child = annotate_arg(child, id);
            }
            child
        } else {
            annotate_path(child, &path[1..], args)
        }
    })
}

pub(crate) fn terminal_command() -> clap::Command {
    let mut command = Cli::command();
    for policy in COMMANDS {
        command = match policy.availability {
            Availability::Comment => {
                command.mut_subcommand(policy.name, |child| annotate_about(child, "comment"))
            }
            Availability::Ci => {
                command.mut_subcommand(policy.name, |child| annotate_about(child, "CI"))
            }
            Availability::Shared | Availability::Terminal => command,
        };
    }
    for leaf in LEAVES {
        command = annotate_path(command, leaf.path, leaf.comment_args);
    }
    command
}

fn validate_terminal(matches: &clap::ArgMatches) -> Result<()> {
    let (name, mut args) = matches
        .subcommand()
        .ok_or_else(|| Error::Request("terminal names no command".into()))?;
    let top = policy(COMMANDS, name)?;
    if top.availability == Availability::Comment {
        return Err(Error::Request(format!("{name} is comment only")));
    }
    let mut path = vec![name];
    if name == "versions" {
        let (verb, nested) = args
            .subcommand()
            .ok_or_else(|| Error::Request("versions names no command".into()))?;
        path.push(verb);
        args = nested;
    }
    if let Some(leaf) = LEAVES.iter().find(|leaf| leaf.path == path) {
        if let Some(id) = leaf
            .comment_args
            .iter()
            .find(|id| command_line_value(args, id))
        {
            return Err(Error::Request(format!(
                "--{} is comment only",
                id.replace('_', "-")
            )));
        }
    }
    Ok(())
}

pub(crate) fn parse_terminal() -> Result<Cli> {
    let mut command = terminal_command();
    let matches = command
        .try_get_matches_from_mut(crate::support::env::args_os())
        .map_err(clap_error)?;
    validate_terminal(&matches)?;
    Cli::from_arg_matches(&matches).map_err(clap_error)
}

fn command_at<'a>(mut command: &'a clap::Command, path: &[&str]) -> &'a clap::Command {
    for segment in path {
        command = command
            .find_subcommand(segment)
            .expect("surface policy names a missing command");
    }
    command
}

pub(crate) fn comment_help() -> Markdown {
    let command = Cli::command();
    let entries = LEAVES.iter().map(|leaf| {
        let mut projected = command_at(&command, leaf.path)
            .clone()
            .bin_name(format!("/wasinix {}", leaf.path.join(" ")));
        for id in leaf.terminal_args.iter().chain(ROOT_TERMINAL_ARGS) {
            if projected.get_arguments().any(|arg| arg.get_id() == *id) {
                projected = projected.mut_arg(*id, |arg| arg.hide(true));
            }
        }
        let usage = projected
            .render_usage()
            .to_string()
            .trim_start_matches("Usage: ")
            .to_string();
        let about = projected
            .get_about()
            .map(ToString::to_string)
            .unwrap_or_default();
        let help = projected.render_long_help().to_string();
        Markdown::concat([
            Markdown::constant("<details><summary>"),
            Markdown::code(&usage),
            Markdown::constant(": "),
            Markdown::text(&about),
            Markdown::constant("</summary>\n\n"),
            Markdown::fenced(&help, "text"),
            Markdown::constant("</details>\n"),
        ])
    });
    Markdown::constant("### `/wasinix` commands\n\n")
        .push(Markdown::join(entries, "\n"))
        .push(Markdown::constant(
            "\n\nAny line of a comment works; the command runs against this pull request.\n",
        ))
}

pub(crate) fn parse_comment(words: &[String]) -> Result<Cli> {
    let mut command = Cli::command();
    let matches = command
        .try_get_matches_from_mut(
            std::iter::once("wasinix").chain(words.iter().map(String::as_str)),
        )
        .map_err(clap_error)?;
    terminal_only(&matches, ROOT_TERMINAL_ARGS)?;
    let (name, mut args) = matches
        .subcommand()
        .ok_or_else(|| Error::Request("comment names no command".into()))?;
    reject_unavailable(policy(COMMANDS, name)?, name)?;

    let mut path = vec![name];
    if name == "versions" {
        let (verb, nested) = args
            .subcommand()
            .ok_or_else(|| Error::Request("versions names no command".into()))?;
        let display = format!("versions {verb}");
        reject_unavailable(policy(VERSION_COMMANDS, verb)?, &display)?;
        path.push(verb);
        args = nested;
    }
    let leaf = LEAVES
        .iter()
        .find(|leaf| leaf.path == path)
        .ok_or_else(|| {
            Error::Request(format!("{} has no command-surface policy", path.join(" ")))
        })?;
    terminal_only(args, leaf.terminal_args)?;
    Cli::from_arg_matches(&matches).map_err(clap_error)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use clap::CommandFactory;

    use super::{Cli, COMMANDS, LEAVES, ROOT_TERMINAL_ARGS, VERSION_COMMANDS};

    fn names(values: impl Iterator<Item = impl ToString>) -> BTreeSet<String> {
        values.map(|value| value.to_string()).collect()
    }

    #[test]
    fn every_command_tree_node_has_surface_policy() {
        let command = Cli::command();
        assert_eq!(
            names(command.get_arguments().filter_map(|arg| {
                let id = arg.get_id().as_str();
                (!matches!(id, "help" | "version")).then_some(id)
            })),
            names(ROOT_TERMINAL_ARGS.iter().copied()),
        );
        assert_eq!(
            names(command.get_subcommands().map(|sub| sub.get_name())),
            names(COMMANDS.iter().map(|policy| policy.name)),
        );
        let versions = command.find_subcommand("versions").unwrap();
        assert_eq!(
            names(versions.get_subcommands().map(|sub| sub.get_name())),
            names(VERSION_COMMANDS.iter().map(|policy| policy.name)),
        );
    }

    #[test]
    fn every_shared_leaf_argument_has_surface_policy() {
        let command = Cli::command();
        for leaf in LEAVES {
            let mut node = &command;
            for segment in leaf.path {
                node = node.find_subcommand(segment).unwrap();
            }
            let actual = names(node.get_arguments().filter_map(|arg| {
                let id = arg.get_id().as_str();
                (!matches!(id, "help" | "verbose" | "quiet" | "color")).then_some(id)
            }));
            let classified = names(
                leaf.shared_args
                    .iter()
                    .chain(leaf.terminal_args)
                    .chain(leaf.comment_args)
                    .copied(),
            );
            assert_eq!(actual, classified, "{}", leaf.path.join(" "));
        }
    }

    #[test]
    fn mutation_effects_stay_classified_consistently() {
        for path in [["update"].as_slice(), ["versions", "bump"].as_slice()] {
            let leaf = LEAVES.iter().find(|leaf| leaf.path == path).unwrap();
            assert!(super::MUTATION_EFFECTS
                .iter()
                .all(|effect| leaf.terminal_args.contains(effect)));
        }
    }

    #[test]
    fn comment_help_is_projected_from_comment_policy() {
        let help = super::comment_help().into_string();
        for text in [
            "/wasinix build",
            "--blocked",
            "/wasinix versions bump",
            "--changed",
            "--plan",
        ] {
            assert!(help.contains(text), "missing {text}: {help}");
        }
        for text in [
            "--run-dir",
            "--changed-from",
            "/wasinix jobs",
            "/wasinix ci",
        ] {
            assert!(!help.contains(text), "included {text}: {help}");
        }
    }

    #[test]
    fn terminal_help_and_validation_name_non_terminal_nodes() {
        let command = super::terminal_command();
        let root = command.clone().render_long_help().to_string();
        assert!(root.contains("CI only"), "{root}");
        assert!(root.contains("comment only"), "{root}");

        let mut versions = command.find_subcommand("versions").unwrap().clone();
        let bump = versions
            .find_subcommand_mut("bump")
            .unwrap()
            .render_long_help()
            .to_string();
        assert!(bump.contains("--changed"), "{bump}");
        assert!(bump.contains("comment only"), "{bump}");

        for words in [
            ["wasinix", "fmt"].as_slice(),
            ["wasinix", "versions", "bump", "--changed"].as_slice(),
        ] {
            let mut parser = super::terminal_command();
            let matches = parser.try_get_matches_from_mut(words).unwrap();
            let error = super::validate_terminal(&matches).unwrap_err().to_string();
            assert!(error.contains("comment only"), "{error}");
        }
        let mut parser = super::terminal_command();
        let matches = parser
            .try_get_matches_from_mut(["wasinix", "build", "core", "--plan"])
            .unwrap();
        super::validate_terminal(&matches).unwrap();
    }
}
