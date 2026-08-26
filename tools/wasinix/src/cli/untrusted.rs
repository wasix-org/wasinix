//! PR-comment commands use the main Clap tree. This module tokenizes the
//! comment and projects authorization, presentation, and requests from that
//! tree without defining another command hierarchy.

use crate::ci::origin::{Classifier, CommandKind};
use crate::ci::types::{ParsedRequest, Request, RequestAction};
use crate::support::error::{Result, request_error};

use super::CommandTree;

const MAX_WORDS: usize = 64;

/// Shell-style word splitting: quotes group, backslash escapes, and an
/// unbalanced quote is an error rather than a guess.
pub fn split_words(command: &str) -> Result<Vec<String>> {
    let mut words = Vec::new();
    let mut current = String::new();
    let mut quote: Option<char> = None;
    let mut started = false;
    let mut chars = command.chars().peekable();
    while let Some(c) = chars.next() {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                } else if c == '\\' && q == '"' {
                    match chars.next() {
                        Some(next) => current.push(next),
                        None => return request_error("unbalanced escape in command"),
                    }
                } else {
                    current.push(c);
                }
            }
            None if c == '\'' || c == '"' => {
                quote = Some(c);
                started = true;
            }
            None if c == '\\' => match chars.next() {
                Some(next) => {
                    current.push(next);
                    started = true;
                }
                None => return request_error("unbalanced escape in command"),
            },
            None if c.is_whitespace() => {
                if started {
                    words.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            None => {
                current.push(c);
                started = true;
            }
        }
    }
    if quote.is_some() {
        return request_error("unbalanced quote in command");
    }
    if started {
        words.push(current);
    }
    Ok(words)
}

fn plain_words(words: &[String]) -> bool {
    words.iter().all(|word| {
        !word.is_empty()
            && !word.contains(['\'', '"', '\\'])
            && !word.chars().any(char::is_whitespace)
    })
}

impl super::update::UpdateArgs {
    pub(crate) fn comment_recipe(&self) -> Option<String> {
        if self.all {
            Some("update --all".into())
        } else {
            (!self.targets.is_empty() && plain_words(&self.targets))
                .then(|| format!("update {}", self.targets.join(" ")))
        }
    }
}

impl super::update::VersionsCommand {
    pub(crate) fn comment_recipe(&self) -> Option<String> {
        match self {
            Self::Bump { changed: true, .. } => Some("versions bump --changed".into()),
            Self::Bump {
                specs,
                all_versions,
                ..
            } => (!specs.is_empty() && plain_words(specs)).then(|| {
                let versions = if *all_versions { " --all-versions" } else { "" };
                format!("versions bump {}{versions}", specs.join(" "))
            }),
            Self::Add { .. } | Self::Import { .. } => None,
        }
    }
}

/// A replayable recipe for a mutation grammar node. A regenerate replays an
/// existing recipe and therefore does not have one of its own.
pub(crate) fn mutation_recipe(command: &CommandTree) -> Option<String> {
    match command {
        CommandTree::Update(args) => args.comment_recipe(),
        CommandTree::Versions(args) => args.comment_recipe(),
        CommandTree::Fmt => Some("fmt".into()),
        CommandTree::Regenerate => None,
        _ => None,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct Presentation {
    pub heading: &'static str,
    pub target: Option<String>,
}

fn selection<'a>(values: impl Iterator<Item = &'a str>) -> Option<String> {
    let values: Vec<&str> = values.collect();
    match values.as_slice() {
        [] => None,
        [one] => Some((*one).to_string()),
        [one, two] => Some(format!("{one}, {two}")),
        [one, rest @ ..] => Some(format!("{one} +{}", rest.len())),
    }
}

impl Presentation {
    pub fn request<S>(request: &Request<S>, plan: bool) -> Presentation {
        let (heading, action, target) = match &request.action {
            RequestAction::Build(build) => (
                "Wasinix build",
                "build",
                selection(
                    build
                        .selectors
                        .iter()
                        .map(|selector| selector.name.as_str()),
                ),
            ),
            RequestAction::Spot(spot) => (
                "Wasinix spot",
                "spot",
                selection(spot.targets.iter().map(String::as_str)),
            ),
            RequestAction::Diff(_) => ("Wasinix diff", "diff", None),
        };
        if plan {
            Presentation {
                heading: "Wasinix plan",
                target: Some(match target {
                    Some(target) => format!("{action} {target}"),
                    None => action.to_string(),
                }),
            }
        } else {
            Presentation { heading, target }
        }
    }
}

pub(crate) fn is_plan(command: &CommandTree) -> bool {
    match command {
        CommandTree::Build(args) => args.mode.plan,
        CommandTree::Spot(args) => args.mode.plan,
        CommandTree::Diff(args) => args.mode.plan,
        _ => false,
    }
}

pub(crate) fn request(command: &CommandTree) -> Result<ParsedRequest> {
    match command {
        CommandTree::Build(args) => Ok(Request::build(
            super::request::build_case(&args.request, Some("local".to_string()), None)?,
            args.outcome.blocked,
        )),
        CommandTree::Spot(args) => Ok(Request::spot(
            super::request::spot_case(&args.request, &args.spot, Some("local".to_string()), None)?,
            args.outcome.blocked,
        )),
        CommandTree::Diff(args) => super::request::diff_request(args, super::Surface::Comment),
        _ => request_error("the command is not a build request"),
    }
}

fn project_presentation(command: CommandTree) -> Result<Presentation> {
    let plan = is_plan(&command);
    Ok(match command {
        CommandTree::Build(_) | CommandTree::Spot(_) | CommandTree::Diff(_) => {
            Presentation::request(&request(&command)?, plan)
        }
        CommandTree::Bisect(args) => Presentation {
            heading: "Wasinix bisect",
            target: Some(args.target),
        },
        CommandTree::Update(_) => Presentation {
            heading: "Wasinix update",
            target: None,
        },
        CommandTree::Versions(_) => Presentation {
            heading: "Wasinix versions",
            target: None,
        },
        CommandTree::Regenerate => Presentation {
            heading: "Wasinix regenerate",
            target: None,
        },
        CommandTree::Fmt => Presentation {
            heading: "Wasinix fmt",
            target: None,
        },
        CommandTree::SurfaceHelp => Presentation {
            heading: "Wasinix commands",
            target: None,
        },
        _ => unreachable!("comment surface accepted a non-comment command"),
    })
}

pub fn presentation(command: &str) -> Result<Presentation> {
    let command = command
        .strip_prefix(crate::ci::origin::PREFIX)
        .map(str::trim_start)
        .unwrap_or(command);
    project_presentation(parse(command)?)
}

/// Parse an untrusted `/wasinix` command with the shared command grammar.
pub fn parse(command: &str) -> Result<CommandTree> {
    let words = split_words(command)?;
    if words.len() > MAX_WORDS {
        return request_error(format!("command has more than {MAX_WORDS} words"));
    }
    let command = super::surface::parse_comment(&words)?.command;
    match &command {
        CommandTree::Build(_) | CommandTree::Spot(_) | CommandTree::Diff(_) => {
            request(&command)?;
        }
        CommandTree::Bisect(args) => {
            bisect_predicate(args)?;
        }
        _ => {}
    }
    Ok(command)
}

pub(crate) fn bisect_predicate(
    args: &super::bisect::BisectArgs,
) -> Result<(Vec<String>, ParsedRequest)> {
    let words: Vec<String> = args
        .command
        .iter()
        .skip_while(|word| *word == "--")
        .cloned()
        .collect();
    let predicate = super::bisect::predicate(
        &words,
        &args.target,
        args.outcome.blocked,
        super::Surface::Comment,
    )?;
    Ok((words, predicate))
}

fn command_kind(command: &CommandTree) -> CommandKind {
    match command {
        CommandTree::Build(args) if args.mode.plan => CommandKind::Plan,
        CommandTree::Spot(args) if args.mode.plan => CommandKind::Plan,
        CommandTree::Diff(args) if args.mode.plan => CommandKind::Plan,
        CommandTree::Build(_)
        | CommandTree::Spot(_)
        | CommandTree::Diff(_)
        | CommandTree::Bisect(_) => CommandKind::Build,
        CommandTree::Update(_)
        | CommandTree::Versions(_)
        | CommandTree::Regenerate
        | CommandTree::Fmt => CommandKind::Mutation,
        CommandTree::SurfaceHelp => CommandKind::Help,
        _ => unreachable!("comment surface accepted a non-comment command"),
    }
}

/// The origin seam's classifier, backed by the real grammar: a command that
/// does not parse cannot be classified, let alone authorized.
pub struct ClapClassifier;

impl Classifier for ClapClassifier {
    fn classify(&self, command: &str) -> Result<CommandKind> {
        Ok(command_kind(&parse(command)?))
    }
}
