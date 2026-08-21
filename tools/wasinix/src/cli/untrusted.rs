//! PR-comment build commands use the main Clap tree, then surface policy
//! rejects effects the workflow adapter owns before typed conversion.

use clap::Parser;

use crate::ci::origin::{Classifier, CommandKind};
use crate::ci::types::{ParsedRequest, Request};
use crate::support::error::{Error, Result, request_error};

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

/// The mutation verbs a PR comment may ask for. The adapter owns branches,
/// tokens, and commit flags, so none of those are spellable here.
#[derive(clap::Args)]
struct UntrustedUpdate {
    /// Targets; empty replays a managed PR's recorded recipe
    targets: Vec<String>,
    /// Update every target
    #[arg(long, conflicts_with = "targets")]
    all: bool,
}

#[derive(Parser)]
#[command(name = "versions", no_binary_name = true)]
enum UntrustedVersions {
    /// Bump publication release counters (+wasix.N)
    Bump {
        /// Packages, optionally @<version>
        #[arg(required_unless_present = "changed")]
        specs: Vec<String>,
        /// Bump every version a package serves
        #[arg(long)]
        all_versions: bool,
        /// Select served versions whose publication derivations changed
        /// from the pull request's base
        #[arg(long, conflicts_with_all = ["specs", "all_versions"])]
        changed: bool,
    },
}

#[derive(Parser)]
#[command(
    name = "/wasinix",
    no_binary_name = true,
    disable_help_flag = true,
    disable_help_subcommand = true
)]
enum UntrustedCli {
    Update(UntrustedUpdate),
    #[command(subcommand)]
    Versions(UntrustedVersions),
    /// Discard the branch and rebuild it from the recorded recipe
    Regenerate,
    /// Run the repo's formatter over the pull request's tree
    Fmt,
    /// Reply with the command language
    Help,
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

/// The reply `/wasinix help` posts.
pub const HELP: &str = "### `/wasinix` commands\n\n\
    - `/wasinix build <selectors>` builds sets or jobs on this PR\n\
    - `/wasinix spot <targets>` rebuilds targets over a cached base\n\
    - `/wasinix diff build ... --vs build ...` compares two cases\n\
    - `/wasinix bisect <target> --good <ref> --bad <ref> -- build <selectors>` \
    finds the dependency commit that broke it (`--reverse` for the one that \
    fixed it)\n\
    - `/wasinix update [targets|--all]` refreshes pins (bare on a managed PR \
    replays its recipe)\n\
    - `/wasinix versions bump <specs|--changed>` bumps publication rels\n\
    - `/wasinix fmt` formats the branch and commits the result\n\
    - `/wasinix regenerate` discards a managed branch and rebuilds it from \
    its recipe\n\
    - `/wasinix help` prints this message\n\n\
    Any line of a comment works; the command runs against this pull request.\n";

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
    Bisect(BisectCommand),
    Mutation(MutationCommand),
    Help,
}

fn shared_command(words: &[String]) -> Result<UntrustedCommand> {
    let parsed = super::surface::parse_comment(words)?;
    Ok(match parsed.command {
        super::CommandTree::Build(args) => UntrustedCommand::Request(Request::build(
            super::request::build_case(&args.request, Some("local".to_string()), None)?,
            args.outcome.blocked,
        )),
        super::CommandTree::Spot(args) => UntrustedCommand::Request(Request::spot(
            super::request::spot_case(
                &args.request,
                &args.spot,
                Some("local".to_string()),
                None,
            )?,
            args.outcome.blocked,
        )),
        super::CommandTree::Diff(args) => UntrustedCommand::Request(
            super::request::diff_request(&args, super::Surface::Comment)?,
        ),
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
        _ => unreachable!("comment surface accepted a non-comment command"),
    })
}

/// Parse an untrusted `/wasinix` command into the shared request family.
pub fn parse(command: &str) -> Result<UntrustedCommand> {
    let words = split_words(command)?;
    if words.len() > MAX_WORDS {
        return request_error(format!("command has more than {MAX_WORDS} words"));
    }
    if !matches!(
        words.first().map(String::as_str),
        Some("update" | "versions" | "regenerate" | "fmt" | "help")
    ) {
        return shared_command(&words);
    }
    let parsed = UntrustedCli::try_parse_from(&words).map_err(|error| {
        // clap renders its own "error: " prefix; the caller adds one too, so
        // it comes off here or every refusal reads "error: error:".
        let rendered = error.to_string();
        Error::Request(
            rendered
                .strip_prefix("error: ")
                .unwrap_or(&rendered)
                .to_string(),
        )
    })?;
    Ok(match parsed {
        UntrustedCli::Help => UntrustedCommand::Help,
        UntrustedCli::Update(args) => UntrustedCommand::Mutation(MutationCommand::Update {
            targets: args.targets,
            all: args.all,
        }),
        UntrustedCli::Versions(UntrustedVersions::Bump {
            specs,
            all_versions,
            changed,
        }) => UntrustedCommand::Mutation(MutationCommand::Bump {
            specs,
            all_versions,
            changed,
        }),
        UntrustedCli::Regenerate => UntrustedCommand::Mutation(MutationCommand::Regenerate),
        UntrustedCli::Fmt => UntrustedCommand::Mutation(MutationCommand::Format),
    })
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
            UntrustedCommand::Help => Ok(CommandKind::Help),
            UntrustedCommand::Mutation(_) => Ok(CommandKind::Mutation),
        }
    }
}
