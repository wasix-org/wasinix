//! The registry nouns and their meta fan-outs. The verbs mean the same in
//! every column: serve is local and ephemeral, publish pushes what is
//! missing, preview is an ephemeral deploy; an empty cell says so honestly.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::registries::{cargo, python, wasmer};
use crate::support::effects::Effects;
use crate::support::error::{Error, Result, request_error};
use crate::support::process::CommandStatus;
use crate::support::ui;

#[derive(clap::Subcommand)]
pub enum CargoCommand {
    /// Stand the overlay registry up locally, seeded from the fresh mint
    Serve {
        #[arg(long, default_value_t = 8319)]
        port: u16,
        /// Keep registry storage here instead of a scratch directory
        #[arg(long)]
        data: Option<PathBuf>,
        /// A built mint to serve; built fresh when absent
        #[arg(long)]
        mint: Option<PathBuf>,
        /// A built server package; built fresh when absent
        #[arg(long)]
        server: Option<PathBuf>,
        /// Run a command against the live registry and exit with its status
        #[arg(last = true)]
        exec: Vec<String>,
    },
    /// Publish minted crates the deployed registry lacks
    Publish {
        /// Crates, optionally @<version>; none means the whole mint
        crates: Vec<String>,
        /// The deployed registry's base URL
        #[arg(long, default_value = cargo::DEPLOYED_REGISTRY)]
        registry: String,
        /// A built mint; built fresh when absent
        #[arg(long)]
        mint: Option<PathBuf>,
        #[arg(long)]
        dry_run: bool,
        #[command(flatten)]
        json: ui::JsonArg,
    },
    /// Deploy the mint (or its diff against a base) as a static sparse index
    Preview {
        /// The app name; one per pull request
        app: String,
        #[arg(long, default_value = "wasmer")]
        owner: String,
        /// Registry hosting the ephemeral app
        #[arg(long, default_value = "wasmer.wtf")]
        registry: String,
        /// A built mint; built fresh when absent
        #[arg(long)]
        mint: Option<PathBuf>,
        /// A built base mint; only crates that differ from it deploy
        #[arg(long)]
        base: Option<PathBuf>,
        #[arg(long)]
        dry_run: bool,
    },
}

#[derive(clap::Subcommand)]
pub enum WasmerCommand {
    /// Materialize shipped webcs and their closures as one offline tree
    Serve {
        /// Packages, as attr paths or abbreviations; none means all shipped
        packages: Vec<String>,
        /// Materialize the tree here; a kept temp directory when absent
        #[arg(long)]
        out: Option<PathBuf>,
        /// Prebuilt webc trees or files to merge in without evaluation
        #[arg(long = "webc")]
        webcs: Vec<PathBuf>,
        /// Run a command with WASMER_FLAGS pointing at the tree
        #[arg(last = true)]
        exec: Vec<String>,
    },
    /// Build shipped webc packages and publish the ones the registry lacks
    Publish {
        /// Registry host or URL, e.g. wasmer.io
        #[arg(long, default_value = "wasmer.io")]
        registry: String,
        /// Packages, as attr paths or abbreviations; none means all shipped
        packages: Vec<String>,
        #[arg(long)]
        dry_run: bool,
        /// Skip SHA validation for versions that already exist
        #[arg(long)]
        skip_sha_validation: bool,
        /// Rev recorded in each published README; HEAD, -dirty suffixed, by default
        #[arg(long)]
        rev: Option<String>,
        /// Publish the one selected package under [<namespace>/]<name>[@<version>]
        #[arg(long = "as", value_name = "IDENTITY")]
        publish_as: Option<String>,
    },
    /// Publish changed webcs as <version>-<TAG> prereleases, hidden from latest
    Preview {
        #[arg(value_name = "TAG")]
        tag: String,
        #[arg(long, default_value = "wasmer.io")]
        registry: String,
        /// Namespace the prereleases publish into, never one carrying
        /// released packages
        #[arg(long)]
        namespace: String,
        packages: Vec<String>,
        /// Add transitive dependencies absent from the production registry
        #[arg(long)]
        with_dependencies: bool,
        #[arg(long)]
        dry_run: bool,
        /// Rev recorded in each published README; HEAD, -dirty suffixed, by default
        #[arg(long)]
        rev: Option<String>,
    },
}

#[derive(clap::Subcommand)]
pub enum PythonCommand {
    /// Serve a built or local index over HTTP
    Serve {
        /// A built index; one is built when this is left out
        registry: Option<PathBuf>,
        #[arg(long, default_value_t = 8318)]
        port: u16,
    },
    /// Publish the built index into its app's volume
    Publish {
        /// A built index; one is built when this is left out
        index: Option<PathBuf>,
        /// The revision the published index records
        #[arg(long, default_value = "")]
        rev: String,
        /// Registry host or URL; $WASMER_REGISTRY, then wasmer.io, when absent
        #[arg(long)]
        registry: Option<String>,
        #[arg(long)]
        dry_run: bool,
        /// Upload the index pages even when no wheel is new, for a change in
        /// how a project is listed
        #[arg(long)]
        refresh_listings: bool,
        /// Withdraw the listing of a project that no longer belongs in simple/,
        /// so it stops shadowing PyPI
        #[arg(long)]
        withdraw_stale: bool,
    },
    /// Deploy a built preview index as an ephemeral Edge app
    Preview {
        /// The built site to serve
        site: PathBuf,
        /// The app name; one per pull request
        app: String,
        #[arg(long, default_value = "wasmer")]
        owner: String,
        /// Registry host or URL; $WASMER_REGISTRY, then wasmer.io, when absent
        #[arg(long)]
        registry: Option<String>,
    },
    /// Count served wheels that ship compiled extension modules
    CountNatives {
        /// A built index; one is built when this is left out
        registry: Option<PathBuf>,
        /// Also print the native project names
        #[arg(long)]
        list: bool,
        #[command(flatten)]
        json: ui::JsonArg,
    },
    /// Rank the next Python packages and historical versions to cover
    Coverage {
        /// Survey cutoff by download rank
        #[arg(long, default_value_t = 10_000)]
        cutoff: usize,
        /// Maximum rows per recommendation section
        #[arg(long, default_value_t = 20)]
        limit: usize,
        #[command(flatten)]
        json: ui::JsonArg,
    },
    /// Refresh the vendored PyPI survey data
    Survey {
        #[command(subcommand)]
        command: PythonSurveyCommand,
    },
}

#[derive(clap::Subcommand)]
pub enum PythonSurveyCommand {
    /// Fetch current package metadata and rebuild coverage inputs
    Refresh {
        /// Survey cutoff by download rank
        #[arg(long, default_value_t = 10_000)]
        cutoff: usize,
    },
}

pub fn run_cargo(command: CargoCommand) -> Result<CommandStatus> {
    match command {
        CargoCommand::Serve {
            port,
            data,
            mint,
            server,
            exec,
        } => cargo::serve(cargo::ServeOptions {
            port,
            data,
            mint,
            server,
            exec,
        }),
        CargoCommand::Publish {
            crates,
            registry,
            mint,
            dry_run,
            json,
        } => {
            let (report, status) = cargo::publish(cargo::PublishOptions {
                registry,
                mint,
                crates,
                effects: Effects::from_dry_run(dry_run),
            })?;
            ui::emit(&json, &report, |report| {
                for outcome in &report.outcomes {
                    ui::result(format!(
                        "{} {}@{}  {}",
                        match outcome.action {
                            cargo::Action::Publish if outcome.published => "✓",
                            cargo::Action::Publish => "→",
                            cargo::Action::Skip => "·",
                            cargo::Action::Conflict => "✗",
                        },
                        outcome.name,
                        outcome.version,
                        outcome.detail
                    ));
                }
            })?;
            Ok(status)
        }
        CargoCommand::Preview {
            app,
            owner,
            registry,
            mint,
            base,
            dry_run,
        } => match cargo::preview(cargo::PreviewOptions {
            app: Some(app),
            owner,
            registry,
            mint,
            base_mint: base,
            effects: Effects::from_dry_run(dry_run),
        })? {
            Some((url, specs)) => {
                ui::result(format!("sparse index at {url} · {} crates", specs.len()));
                for spec in specs {
                    ui::result(format!("  {spec}"));
                }
                Ok(CommandStatus::SUCCESS)
            }
            None => {
                ui::result("no crates changed against the base; nothing deployed");
                Ok(CommandStatus::SUCCESS)
            }
        },
    }
}

pub fn run_wasmer(command: WasmerCommand) -> Result<CommandStatus> {
    match command {
        WasmerCommand::Serve {
            packages,
            out,
            webcs,
            exec,
        } => wasmer::serve(wasmer::ServeOptions {
            packages,
            out,
            webcs,
            exec,
        }),
        WasmerCommand::Publish {
            registry,
            packages,
            dry_run,
            skip_sha_validation,
            rev,
            publish_as,
        } => wasmer::publish(wasmer::Options {
            registry,
            packages,
            effects: Effects::from_dry_run(dry_run),
            skip_sha_validation,
            rev,
            preview: None,
            with_dependencies: false,
            publish_as,
            namespace: None,
            provenance: None,
        }),
        WasmerCommand::Preview {
            tag,
            registry,
            namespace,
            packages,
            with_dependencies,
            dry_run,
            rev,
        } => wasmer::publish(wasmer::Options {
            registry,
            packages,
            effects: Effects::from_dry_run(dry_run),
            skip_sha_validation: false,
            rev,
            preview: Some(tag),
            with_dependencies,
            publish_as: None,
            namespace: Some(namespace),
            provenance: None,
        }),
    }
}

pub fn run_python(command: PythonCommand) -> Result<CommandStatus> {
    match command {
        PythonCommand::Serve { registry, port } => python::serve(registry, port),
        PythonCommand::Publish {
            index,
            rev,
            registry,
            dry_run,
            refresh_listings,
            withdraw_stale,
        } => python::publish_index(python::Index {
            registry_path: index,
            registry: python::registry(registry.as_deref()),
            rev,
            effects: Effects::from_dry_run(dry_run),
            repo: crate::support::git::repo_root()?,
            app_directory: "pkgs/python-registry".into(),
            refresh_listings,
            withdraw_stale,
        }),
        PythonCommand::Preview {
            site,
            app,
            owner,
            registry,
        } => {
            let url = python::preview(python::Preview {
                site,
                app,
                owner,
                registry: python::registry(registry.as_deref()),
            })?;
            ui::result(url);
            Ok(CommandStatus::SUCCESS)
        }
        PythonCommand::CountNatives {
            registry,
            list,
            json,
        } => {
            let report = python::count_natives(registry)?;
            ui::emit(&json, &report, |report| {
                let projects = report.native.projects.len() + report.pure.projects.len();
                ui::result(&report.registry);
                ui::result(format!(
                    "native: {} / {projects} projects · {} wheel files",
                    report.native.projects.len(),
                    report.native.files
                ));
                ui::result(format!(
                    "pure: {} / {projects} projects · {} wheel files",
                    report.pure.projects.len(),
                    report.pure.files
                ));
                if list {
                    for project in &report.native.projects {
                        ui::result(format!("  {project}"));
                    }
                }
            })?;
            Ok(CommandStatus::SUCCESS)
        }
        PythonCommand::Coverage {
            cutoff,
            limit,
            json,
        } => {
            let report = python::coverage(cutoff, limit)?;
            ui::emit(&json, &report, |report| {
                ui::result(format!(
                    "top {}: {} buildable · {} blocked · {} out of scope · {} unknown",
                    report.cutoff,
                    report.coverage.buildable,
                    report.coverage.blocked,
                    report.coverage.out_of_scope,
                    report.coverage.unknown,
                ));
                ui::result("publish next:");
                for row in &report.publish {
                    ui::result(format!(
                        "  {} · {:.2}% · {} downloads",
                        row.package,
                        row.share * 100.0,
                        row.downloads,
                    ));
                }
                ui::result("native next:");
                for row in &report.native {
                    ui::result(format!(
                        "  {} · {} projects · {:.2}% · {} downloads",
                        row.package,
                        row.projects,
                        row.downloads as f64 / report.survey.downloads as f64 * 100.0,
                        row.downloads,
                    ));
                }
                ui::result("history next:");
                for row in &report.history {
                    ui::result(format!(
                        "  {}=={} · {:.3}% · {}",
                        row.package,
                        row.version,
                        row.share * 100.0,
                        row.why,
                    ));
                }
            })?;
            Ok(CommandStatus::SUCCESS)
        }
        PythonCommand::Survey {
            command: PythonSurveyCommand::Refresh { cutoff },
        } => {
            python::refresh_survey(cutoff)?;
            Ok(CommandStatus::SUCCESS)
        }
    }
}

type Leg<'a> = Box<dyn FnOnce() -> Result<CommandStatus> + 'a>;

/// The meta verbs: pure fan-out, one section per registry, each section
/// exactly the per-registry command's output. A failed leg folds into the
/// exit code; it never aborts the legs after it.
fn fan_out(legs: Vec<(&str, Leg<'_>)>) -> Result<CommandStatus> {
    let mut worst = CommandStatus::SUCCESS;
    for (name, leg) in legs {
        ui::fact("registry", name);
        match leg() {
            Ok(status) => worst = worst.max(status),
            Err(error) => {
                ui::error(format!("{name}: {error}"));
                worst = worst.max(CommandStatus::FAILURE);
            }
        }
    }
    Ok(worst)
}

#[derive(Deserialize)]
struct Publication {
    catalog: BTreeMap<String, PublicationInfo>,
    destinations: Destinations,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PublishProject {
    publication: Publication,
    selector_catalog: crate::ci::evalmap::SelectorCatalog,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PublicationInfo {
    kind: PublicationKind,
    identity: PublicationIdentity,
    package_subjects: Vec<String>,
}

#[derive(Clone, Copy, Deserialize, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
enum PublicationKind {
    Crate,
    Webc,
    Wheel,
}

#[derive(Clone, Deserialize, Serialize)]
struct PublicationIdentity {
    name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    owner: Option<String>,
}

#[derive(Default, Deserialize)]
struct Destinations {
    cargo: Option<RegistryDestination>,
    python: Option<PythonDestination>,
    wasmer: Option<RegistryDestination>,
    provenance: Option<wasmer::Provenance>,
}

#[derive(Deserialize)]
struct RegistryDestination {
    registry: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PythonDestination {
    registry: String,
    app_directory: PathBuf,
}

fn project_value<T: for<'de> Deserialize<'de>>(path: &str, apply: Option<&str>) -> Result<T> {
    let value = crate::support::nix::eval(&crate::support::nix::Flake::default(), path, apply)?;
    serde_json::from_value(value).map_err(|source| Error::Json {
        path: format!("<{}>", crate::support::nix::project_attr(path)).into(),
        source,
    })
}

fn selected_publications<'a>(
    publication: &'a Publication,
    selectors: &[String],
    selector_catalog: crate::ci::evalmap::SelectorCatalog,
) -> Result<Vec<(&'a str, &'a PublicationInfo)>> {
    if selectors.is_empty() {
        return Ok(publication
            .catalog
            .iter()
            .map(|(address, info)| (address.as_str(), info))
            .collect());
    }
    let selected: BTreeSet<String> = selector_catalog
        .into_map()
        .resolve_jobs(selectors)?
        .into_iter()
        .collect();
    Ok(publication
        .catalog
        .iter()
        .filter(|(address, info)| {
            selected.contains(*address)
                || info
                    .package_subjects
                    .iter()
                    .any(|subject| selected.contains(subject))
        })
        .map(|(address, info)| (address.as_str(), info))
        .collect())
}

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublicationPlanArtifact {
    address: String,
    identity: PublicationIdentity,
}

#[derive(Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
enum PublicationPlanLeg {
    Wasmer {
        registry: String,
        provenance: wasmer::Provenance,
        artifacts: Vec<PublicationPlanArtifact>,
    },
    Python {
        registry: String,
        #[serde(rename = "appDirectory")]
        app_directory: PathBuf,
        artifacts: Vec<PublicationPlanArtifact>,
    },
    Cargo {
        registry: String,
        artifacts: Vec<PublicationPlanArtifact>,
    },
}

#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublicationPlan {
    project_schema_version: u64,
    selectors: Vec<String>,
    legs: Vec<PublicationPlanLeg>,
}

impl crate::support::schema::Document for PublicationPlan {
    const KIND: &'static str = "publicationPlan";
    const SCHEMA: u32 = 1;
}

fn publication_plan(project: PublishProject, selectors: &[String]) -> Result<PublicationPlan> {
    let expected_schema = crate::support::schema::project_version();
    if project.selector_catalog.schema_version != expected_schema {
        return request_error(format!(
            "publication catalog uses Wasinix project schema {}; this wasinix supports schema {expected_schema}",
            project.selector_catalog.schema_version
        ));
    }
    let selected =
        selected_publications(&project.publication, selectors, project.selector_catalog)?;
    if selected.is_empty() {
        return request_error("the publication selectors matched no publishable artifacts");
    }
    let artifacts = |kind| {
        selected
            .iter()
            .filter(|(_, info)| info.kind == kind)
            .map(|(address, info)| PublicationPlanArtifact {
                address: (*address).to_string(),
                identity: info.identity.clone(),
            })
            .collect::<Vec<_>>()
    };
    let webcs = artifacts(PublicationKind::Webc);
    let wheels = artifacts(PublicationKind::Wheel);
    let crates = artifacts(PublicationKind::Crate);
    let destinations = project.publication.destinations;
    let mut legs = Vec::new();
    if !webcs.is_empty() {
        let Some(destination) = destinations.wasmer else {
            return request_error(
                "selected WebC artifacts have no repository.publication.wasmer destination",
            );
        };
        let Some(provenance) = destinations.provenance else {
            return request_error(
                "selected WebC artifacts have no repository.publication.provenance",
            );
        };
        legs.push(PublicationPlanLeg::Wasmer {
            registry: destination.registry,
            provenance,
            artifacts: webcs,
        });
    }
    if !wheels.is_empty() {
        let Some(destination) = destinations.python else {
            return request_error(
                "selected wheels have no repository.publication.python destination",
            );
        };
        legs.push(PublicationPlanLeg::Python {
            registry: destination.registry,
            app_directory: destination.app_directory,
            artifacts: wheels,
        });
    }
    if !crates.is_empty() {
        let Some(destination) = destinations.cargo else {
            return request_error(
                "selected crates have no repository.publication.cargo destination",
            );
        };
        legs.push(PublicationPlanLeg::Cargo {
            registry: destination.registry,
            artifacts: crates,
        });
    }
    Ok(PublicationPlan {
        project_schema_version: expected_schema,
        selectors: selectors.to_vec(),
        legs,
    })
}

fn execute_publication_plan(
    plan: PublicationPlan,
    with_dependencies: bool,
    effects: Effects,
) -> Result<CommandStatus> {
    let repo = crate::support::git::repo_root()?;
    let mut legs: Vec<(&str, Leg<'_>)> = Vec::new();
    for leg in plan.legs {
        match leg {
            PublicationPlanLeg::Wasmer {
                registry,
                provenance,
                artifacts,
            } => legs.push((
                "wasmer",
                Box::new(move || {
                    wasmer::publish(wasmer::Options {
                        registry,
                        packages: artifacts
                            .into_iter()
                            .map(|artifact| artifact.identity.name)
                            .collect(),
                        effects,
                        skip_sha_validation: false,
                        rev: None,
                        preview: None,
                        with_dependencies,
                        publish_as: None,
                        namespace: None,
                        provenance: Some(provenance),
                    })
                }),
            )),
            PublicationPlanLeg::Python {
                registry,
                app_directory,
                ..
            } => {
                let repo = repo.clone();
                legs.push((
                    "python",
                    Box::new(move || {
                        python::publish_index(python::Index {
                            registry_path: None,
                            registry,
                            rev: String::new(),
                            effects,
                            repo,
                            app_directory,
                            refresh_listings: false,
                            withdraw_stale: false,
                        })
                    }),
                ));
            }
            PublicationPlanLeg::Cargo {
                registry,
                artifacts,
            } => legs.push((
                "cargo",
                Box::new(move || {
                    run_cargo(CargoCommand::Publish {
                        crates: artifacts
                            .into_iter()
                            .map(|artifact| artifact.identity.name)
                            .collect(),
                        registry,
                        mint: None,
                        dry_run: effects.is_dry_run(),
                        json: Default::default(),
                    })
                }),
            )),
        }
    }
    fan_out(legs)
}

pub fn run_meta_publish(
    selectors: &[String],
    with_dependencies: bool,
    effects: Effects,
    plan_only: bool,
    json: ui::JsonArg,
) -> Result<CommandStatus> {
    if json.wants() && !plan_only {
        return request_error("publish --json requires --plan");
    }
    let project: PublishProject = project_value(
        "",
        Some(
            "p: { publication = { inherit (p.internals.repository.publication) catalog destinations; }; selectorCatalog = p.ci.catalog; }",
        ),
    )?;
    let plan = publication_plan(project, selectors)?;
    if plan_only {
        ui::emit(&json, &plan, |plan| {
            for leg in &plan.legs {
                let (kind, registry, count) = match leg {
                    PublicationPlanLeg::Wasmer {
                        registry,
                        artifacts,
                        ..
                    } => ("wasmer", registry, artifacts.len()),
                    PublicationPlanLeg::Python {
                        registry,
                        artifacts,
                        ..
                    } => ("python", registry, artifacts.len()),
                    PublicationPlanLeg::Cargo {
                        registry,
                        artifacts,
                    } => ("cargo", registry, artifacts.len()),
                };
                ui::fact(kind, format!("{count} artifacts -> {registry}"));
            }
        })?;
        Ok(CommandStatus::SUCCESS)
    } else {
        execute_publication_plan(plan, with_dependencies, effects)
    }
}

#[cfg(test)]
mod publication_tests {
    use super::{Publication, PublishProject, publication_plan, selected_publications};

    #[test]
    fn source_selection_reaches_publications_through_package_subjects() {
        let publication: Publication = serde_json::from_value(serde_json::json!({
            "catalog": {
                "artifacts.webc.consumer": {
                    "kind": "webc",
                    "identity": { "name": "consumer" },
                    "packageSubjects": ["packages.wasix.default.consumer"]
                }
            },
            "destinations": {}
        }))
        .unwrap();
        let selector_catalog = serde_json::from_value(serde_json::json!({
            "schemaVersion": crate::support::schema::project_version(),
            "jobs": {
                "packages.native.tool": {
                    "kind": "package",
                    "name": "tool",
                    "packageSubjects": ["packages.native.tool"]
                },
                "packages.wasix.default.consumer": {
                    "kind": "package",
                    "name": "consumer",
                    "packageSubjects": ["packages.wasix.default.consumer"]
                }
            },
            "selectors": {
                "sets": { "all": ["packages.native.tool", "packages.wasix.default.consumer"] },
                "sources": {
                    "consumer": ["packages.native.tool", "packages.wasix.default.consumer"]
                }
            }
        }))
        .unwrap();
        let selected =
            selected_publications(&publication, &["source=consumer".into()], selector_catalog)
                .unwrap();

        assert_eq!(selected.len(), 1);
        assert_eq!(selected[0].0, "artifacts.webc.consumer");
        assert_eq!(selected[0].1.identity.name, "consumer");
    }

    #[test]
    fn a_publication_plan_is_the_sorted_network_free_boundary() {
        let project: PublishProject = serde_json::from_value(serde_json::json!({
            "publication": {
                "catalog": {
                    "artifacts.webc.second": {
                        "kind": "webc",
                        "identity": { "name": "second", "owner": "example" },
                        "packageSubjects": ["packages.wasix.default.second"]
                    },
                    "artifacts.webc.first": {
                        "kind": "webc",
                        "identity": { "name": "first", "owner": "example" },
                        "packageSubjects": ["packages.wasix.default.first"]
                    }
                },
                "destinations": {
                    "wasmer": { "registry": "registry.example" },
                    "provenance": {
                        "flake": "github:example/project",
                        "repository": "example/project"
                    }
                }
            },
            "selectorCatalog": {
                "schemaVersion": crate::support::schema::project_version(),
                "jobs": {},
                "selectors": { "sets": {}, "sources": {} }
            }
        }))
        .unwrap();
        let value =
            crate::support::schema::to_value(&publication_plan(project, &[]).unwrap()).unwrap();

        assert_eq!(value["kind"], "publicationPlan");
        assert_eq!(value["projectSchemaVersion"], 1);
        assert_eq!(
            value["legs"][0]["artifacts"][0]["address"],
            "artifacts.webc.first"
        );
        assert_eq!(
            value["legs"][0]["artifacts"][1]["address"],
            "artifacts.webc.second"
        );
    }
}

/// All three registries at once: the cargo server (slowest up, fails
/// fastest), the python index, and the offline webc tree. One exit tears the
/// servers down through their guards.
pub fn run_meta_serve(
    mint: Option<PathBuf>,
    index: Option<PathBuf>,
    server: Option<PathBuf>,
    webcs: Vec<PathBuf>,
    exec: Vec<String>,
) -> Result<CommandStatus> {
    let mut cargo = cargo::start(cargo::ServeOptions {
        port: 8319,
        data: None,
        mint,
        server,
        exec: Vec::new(),
    })?;
    let mut python = python::start(index, 8318)?;
    let tree = wasmer::materialize(wasmer::ServeOptions {
        packages: Vec::new(),
        out: None,
        webcs,
        exec: Vec::new(),
    })?;
    ui::fact("cargo", &cargo.base);
    ui::fact("python", &python.url);
    ui::fact("webc tree", tree.display());
    if !exec.is_empty() {
        return wasmer::exec_with_tree(&tree, &exec);
    }
    ui::fact("stop", "Ctrl-C");
    loop {
        if let Some(status) = cargo.exited()? {
            return Ok(CommandStatus::from_exit(status));
        }
        if let Some(status) = python.exited()? {
            return Ok(CommandStatus::from_exit(status));
        }
        std::thread::sleep(std::time::Duration::from_millis(200));
    }
}
