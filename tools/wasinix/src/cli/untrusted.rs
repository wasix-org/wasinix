//! PR-comment commands use the main Clap tree, then surface policy
//! rejects effects the workflow adapter owns before typed conversion.

use crate::ci::origin::{Classifier, CommandKind};
use crate::ci::types::{ParsedRequest, Request};
use crate::support::error::{Result, request_error};

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

/// A parsed mutation, replayable from the recorded recipe text.
#[derive(Debug, Clone, PartialEq)]
pub enum MutationCommand {
    Update {
        targets: Vec<String>,
        all: bool,
    },
    Bump {
        specs: Vec<String>,
        all_versions: bool,
        changed: bool,
    },
    Regenerate,
    Format,
}

/// A word the comment tokenizer returns unchanged, so a recipe built from it
/// re-parses to the same word without quoting.
fn plain_words(words: &[String]) -> bool {
    words.iter().all(|word| {
        !word.is_empty()
            && !word.contains(['\'', '"', '\\'])
            && !word.chars().any(char::is_whitespace)
    })
}

impl MutationCommand {
    /// The comment that replays this mutation, recorded as a managed PR's
    /// recipe. Rendered from the parsed command rather than from the
    /// invocation that produced the branch, so a recorded recipe always
    /// re-parses to what it names. A command that replays a recipe rather
    /// than being one has none.
    pub fn recipe(&self) -> Option<String> {
        match self {
            MutationCommand::Update { all: true, .. } => Some("update --all".into()),
            MutationCommand::Update { targets, .. } => (!targets.is_empty()
                && plain_words(targets))
            .then(|| format!("update {}", targets.join(" "))),
            MutationCommand::Bump { changed: true, .. } => Some("versions bump --changed".into()),
            MutationCommand::Bump {
                specs,
                all_versions,
                ..
            } => (!specs.is_empty() && plain_words(specs)).then(|| {
                let versions = if *all_versions { " --all-versions" } else { "" };
                format!("versions bump {}{versions}", specs.join(" "))
            }),
            MutationCommand::Format => Some("fmt".into()),
            MutationCommand::Regenerate => None,
        }
    }
}

/// A bisect a comment asked for, with its predicate already parsed and
/// pinned to the runner.
#[derive(Debug, Clone, PartialEq)]
pub struct BisectCommand {
    pub target: String,
    pub good: String,
    pub bad: String,
    pub first_parent: bool,
    pub reverse: bool,
    pub words: Vec<String>,
    pub predicate: ParsedRequest,
}

#[derive(Debug)]
pub enum UntrustedCommand {
    Request(ParsedRequest),
    Plan(ParsedRequest),
    Bisect(BisectCommand),
    Mutation(MutationCommand),
    Help,
}

fn request_command(request: ParsedRequest, plan: bool) -> UntrustedCommand {
    if plan {
        UntrustedCommand::Plan(request)
    } else {
        UntrustedCommand::Request(request)
    }
}

fn shared_command(words: &[String]) -> Result<UntrustedCommand> {
    let parsed = super::surface::parse_comment(words)?;
    Ok(match parsed.command {
        super::CommandTree::Build(args) => {
            let request = Request::build(
                super::request::build_case(&args.request, Some("local".to_string()), None)?,
                args.outcome.blocked,
            );
            request_command(request, args.mode.plan)
        }
        super::CommandTree::Spot(args) => {
            let request = Request::spot(
                super::request::spot_case(
                    &args.request,
                    &args.spot,
                    Some("local".to_string()),
                    None,
                )?,
                args.outcome.blocked,
            );
            request_command(request, args.mode.plan)
        }
        super::CommandTree::Diff(args) => {
            let plan = args.mode.plan;
            let request = super::request::diff_request(&args, super::Surface::Comment)?;
            request_command(request, plan)
        }
        super::CommandTree::Bisect(args) => {
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
            UntrustedCommand::Bisect(BisectCommand {
                target: args.target,
                good: args.good,
                bad: args.bad,
                first_parent: args.first_parent,
                reverse: args.reverse,
                words,
                predicate,
            })
        }
        super::CommandTree::Update(args) => {
            UntrustedCommand::Mutation(MutationCommand::Update {
                targets: args.targets,
                all: args.all,
            })
        }
        super::CommandTree::Versions(super::update::VersionsCommand::Bump {
            specs,
            all_versions,
            changed,
            ..
        }) => UntrustedCommand::Mutation(MutationCommand::Bump {
            specs,
            all_versions,
            changed,
        }),
        super::CommandTree::Regenerate => {
            UntrustedCommand::Mutation(MutationCommand::Regenerate)
        }
        super::CommandTree::Fmt => UntrustedCommand::Mutation(MutationCommand::Format),
        super::CommandTree::SurfaceHelp => UntrustedCommand::Help,
        _ => unreachable!("comment surface accepted a non-comment command"),
    })
}

/// Parse an untrusted `/wasinix` command into the shared request family.
pub fn parse(command: &str) -> Result<UntrustedCommand> {
    let words = split_words(command)?;
    if words.len() > MAX_WORDS {
        return request_error(format!("command has more than {MAX_WORDS} words"));
    }
    shared_command(&words)
}

/// The origin seam's classifier, backed by the real grammar: a command that
/// does not parse cannot be classified, let alone authorized.
pub struct ClapClassifier;

impl Classifier for ClapClassifier {
    fn classify(&self, command: &str) -> Result<CommandKind> {
        match parse(command)? {
            // A bisect runs builds and reports; the build job's shape fits
            // it, and it carries no write credential.
            UntrustedCommand::Request(_) | UntrustedCommand::Bisect(_) => Ok(CommandKind::Build),
            UntrustedCommand::Plan(_) => Ok(CommandKind::Plan),
            UntrustedCommand::Help => Ok(CommandKind::Help),
            UntrustedCommand::Mutation(_) => Ok(CommandKind::Mutation),
        }
    }
}
