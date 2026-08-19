//! PR-comment commands re-enter the same selection cores as the terminal,
//! wrapped in a grammar where adapter-owned flags (placement, run
//! directories, cache signing, machine output) do not exist at all: an
//! attempt to use one fails the parse, not a denylist.

use clap::Parser;

use crate::ci::origin::{Classifier, CommandKind};
use crate::ci::types::{Case, ParsedRequest, RefSource, Request};
use crate::support::error::{request_error, Error, Result};

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

#[derive(clap::Args)]
struct UntrustedBuild {
    #[command(flatten)]
    request: super::RequestArgs,
}

#[derive(clap::Args)]
struct UntrustedSpot {
    #[command(flatten)]
    request: super::RequestArgs,
    #[command(flatten)]
    spot: super::SpotExtras,
}

#[derive(clap::Args)]
struct UntrustedDiff {
    /// Also compare the built contents of moved outputs
    #[arg(long)]
    content_diff: bool,
    /// The cases, as build or spot commands separated by --vs
    #[arg(
        required = true,
        trailing_var_arg = true,
        allow_hyphen_values = true,
        value_name = "CASE"
    )]
    words: Vec<String>,
}

/// The untrusted spelling of a diff case: the same selection cores, no
/// placement.
#[derive(Parser)]
#[command(name = "case", no_binary_name = true)]
enum UntrustedCase {
    Build(UntrustedBuild),
    Spot(UntrustedSpot),
}

/// Bisect from a comment. The adapter owns the run directory and the
/// budget; the predicate re-enters the untrusted case grammar, so it is a
/// build or spot pinned to the runner like any other comment command.
#[derive(clap::Args)]
struct UntrustedBisect {
    /// Revision-capable update target, e.g. wasix-libc or wasmer
    target: String,
    /// Known passing ref, or `pinned` for the current pin
    #[arg(long)]
    good: String,
    /// Known failing ref, or `pinned` for the current pin
    #[arg(long)]
    bad: String,
    /// Follow only the first parent of merge commits
    #[arg(long)]
    first_parent: bool,
    /// The build or spot command used as the pass/fail predicate
    #[arg(required = true, trailing_var_arg = true, value_name = "PREDICATE")]
    command: Vec<String>,
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

#[derive(clap::Args)]
struct UntrustedRegenerate {
    /// Discard the branch and regenerate it from the recorded recipe
    #[arg(long, required = true)]
    force: bool,
}

#[derive(Parser)]
#[command(
    name = "/wasinix",
    no_binary_name = true,
    disable_help_flag = true,
    disable_help_subcommand = true
)]
enum UntrustedCli {
    Build(UntrustedBuild),
    Spot(UntrustedSpot),
    Diff(UntrustedDiff),
    Bisect(UntrustedBisect),
    Update(UntrustedUpdate),
    #[command(subcommand)]
    Versions(UntrustedVersions),
    Regenerate(UntrustedRegenerate),
    /// Run the repo's formatter over the pull request's tree
    Fmt,
    /// Reply with the command language
    Help,
}

/// A parsed mutation, replayable from the recorded recipe text.
#[derive(Debug, Clone, PartialEq)]
pub enum MutationCommand {
    Update { targets: Vec<String>, all: bool },
    Bump {
        specs: Vec<String>,
        all_versions: bool,
        changed: bool,
    },
    Regenerate,
    Format,
}

/// The reply `/wasinix help` posts.
pub const HELP: &str = "### `/wasinix` commands\n\n\
    - `/wasinix build <selectors>` builds sets or jobs on this PR\n\
    - `/wasinix spot <targets>` rebuilds targets over a cached base\n\
    - `/wasinix diff build ... --vs build ...` compares two cases\n\
    - `/wasinix bisect <target> --good <ref> --bad <ref> -- build <selectors>` \
    finds the dependency commit that broke it\n\
    - `/wasinix update [targets|--all]` refreshes pins (bare on a managed PR \
    replays its recipe)\n\
    - `/wasinix versions bump <specs|--changed>` bumps publication rels\n\
    - `/wasinix fmt` formats the branch and commits the result\n\
    - `/wasinix regenerate --force` rebuilds a managed branch from its recipe\n\
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

fn untrusted_case(words: &[String], case_id: String) -> Result<Case<RefSource>> {
    let parsed = UntrustedCase::try_parse_from(words)
        .map_err(|error| Error::Request(format!("diff case {case_id}: {error}")))?;
    Ok(match &parsed {
        UntrustedCase::Build(case) => Case::Build(super::request::build_case(
            &case.request,
            Some("local".to_string()),
            Some(case_id),
        )?),
        UntrustedCase::Spot(case) => Case::Spot(super::request::spot_case(
            &case.request,
            &case.spot,
            Some("local".to_string()),
            Some(case_id),
        )?),
    })
}

/// Parse an untrusted `/wasinix` command into the shared request family.
pub fn parse(command: &str) -> Result<UntrustedCommand> {
    let words = split_words(command)?;
    if words.len() > MAX_WORDS {
        return request_error(format!("command has more than {MAX_WORDS} words"));
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
        UntrustedCli::Regenerate(_) => UntrustedCommand::Mutation(MutationCommand::Regenerate),
        UntrustedCli::Fmt => UntrustedCommand::Mutation(MutationCommand::Format),
        // Comment commands execute on the workflow runner itself, and the
        // untrusted grammar rightly cannot spell --on, so every case is
        // pinned local; a runner has no builders.toml to default from.
        UntrustedCli::Build(args) => UntrustedCommand::Request(Request::Build(
            super::request::build_case(&args.request, Some("local".to_string()), None)?,
        )),
        UntrustedCli::Spot(args) => UntrustedCommand::Request(Request::Spot(
            super::request::spot_case(&args.request, &args.spot, Some("local".to_string()), None)?,
        )),
        UntrustedCli::Diff(args) => {
            let mut cases = Vec::new();
            for (case_id, case_words) in super::request::split_cases(&args.words) {
                cases.push(untrusted_case(case_words, case_id)?);
            }
            UntrustedCommand::Request(super::request::diff_of(cases, args.content_diff)?)
        }
        UntrustedCli::Bisect(args) => {
            let words: Vec<String> = args
                .command
                .iter()
                .skip_while(|word| *word == "--")
                .cloned()
                .collect();
            // The predicate is a case like any other, so it arrives pinned
            // and a bisect grows no way to name a builder.
            let predicate = match untrusted_case(&words, "predicate".to_string())? {
                Case::Build(build) => Request::Build(build),
                Case::Spot(spot) => Request::Spot(spot),
            };
            UntrustedCommand::Bisect(BisectCommand {
                target: args.target,
                good: args.good,
                bad: args.bad,
                first_parent: args.first_parent,
                words,
                predicate,
            })
        }
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
