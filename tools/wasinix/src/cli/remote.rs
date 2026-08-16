//! The remote noun: the health and description family for configured
//! builders. Execution goes through `--on`; nothing here starts work.

use std::path::Path;

use crate::nix::builder::{self, Builder, Capability};
use crate::nix::route::Route;
use crate::support::error::{request_error, Result};
use crate::support::process::CommandStatus;
use crate::support::{schema, table, ui};

#[derive(clap::Subcommand)]
pub enum RemoteCommand {
    /// List configured remotes and their capabilities
    List {
        #[command(flatten)]
        json: ui::JsonArg,
    },
    /// Show a remote's lease occupancy and, for a host, its load
    Status {
        /// The remote to inspect; the configured default when absent
        remote: Option<String>,
    },
    /// Verify connectivity and store access, optionally with an IFD round trip
    Doctor {
        remote: Option<String>,
        /// Also build a probe derivation and read it back during evaluation
        #[arg(long)]
        ifd: bool,
    },
    /// Print one remote value for direct nix or ssh commands
    Field {
        #[arg(value_enum)]
        field: BuilderField,
        remote: Option<String>,
    },
    /// Write a commented remotes.toml template to the config path
    Init,
}

#[derive(Clone, Copy, clap::ValueEnum)]
pub enum BuilderField {
    /// ssh-ng store URL for --store and nix copy --to
    Store,
    /// The full --builders spec for a daemon-scheduled build
    Builders,
    /// ssh target, user@hostname
    Host,
    /// The ssh key path
    Key,
}

#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Summary {
    name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    description: Option<String>,
    default: bool,
    capabilities: Vec<Capability>,
}

#[derive(serde::Serialize, serde::Deserialize)]
struct RemoteList {
    remotes: Vec<Summary>,
}

impl schema::Document for RemoteList {
    const KIND: &'static str = "remoteList";
    const SCHEMA: u32 = 1;
}

fn capability_list(builder: &Builder) -> String {
    builder
        .capabilities
        .iter()
        .map(|capability| format!("{capability:?}").to_lowercase())
        .collect::<Vec<_>>()
        .join(",")
}

fn list(repo: &Path, json: ui::JsonArg) -> Result<CommandStatus> {
    let remotes: Vec<Summary> = builder::all(repo)?
        .into_iter()
        .map(|(builder, default)| Summary {
            name: builder.name.clone(),
            description: builder.description.clone(),
            default,
            capabilities: builder.capabilities,
        })
        .collect();
    ui::emit(&json, &RemoteList { remotes }, |list| {
        let rows: Vec<Vec<String>> = list
            .remotes
            .iter()
            .map(|remote| {
                vec![
                    remote.name.clone(),
                    if remote.default { "default" } else { "" }.to_string(),
                    remote
                        .capabilities
                        .iter()
                        .map(|capability| format!("{capability:?}").to_lowercase())
                        .collect::<Vec<_>>()
                        .join(","),
                    remote.description.clone().unwrap_or_default(),
                ]
            })
            .collect();
        ui::output(table::render(
            Some(&["name", "", "capabilities", "description"]),
            &rows,
        ));
    })?;
    Ok(CommandStatus::SUCCESS)
}

fn status(repo: &Path, remote: Option<&str>) -> Result<CommandStatus> {
    let builder = builder::load(repo, remote)?;
    let root = builder::runtime_dir()?.join("leases").join(&builder.name);
    let leases = std::fs::read_dir(&root)
        .map(|entries| entries.flatten().count())
        .unwrap_or(0);
    ui::result(format!(
        "{}: {leases}/{} local leases; capabilities={}",
        builder.name,
        builder.capacity,
        capability_list(&builder)
    ));
    if let Some(description) = &builder.description {
        ui::fact("description", description);
    }
    if builder.supports(Capability::Host) {
        let output = builder.ssh_output(crate::nix::builder::Deadline::Probe,
            "printf 'load='; cut -d' ' -f1-3 /proc/loadavg; \
             printf 'runs='; find \"${XDG_STATE_HOME:-$HOME/.local/state}/wasinix/runs\" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l",
        )?;
        ui::output(&output);
        if !output.ends_with('\n') {
            ui::result("");
        }
    }
    Ok(CommandStatus::SUCCESS)
}

fn doctor(repo: &Path, remote: Option<&str>, ifd: bool) -> Result<CommandStatus> {
    let builder = builder::load(repo, remote)?;
    if builder.supports(Capability::Host) {
        builder.reachable()?;
        ui::result("host: ok");
    }
    if builder.supports(Capability::Store) {
        let store = builder.store();
        let ping = crate::support::nix::Invocation::plain("store info")
            .args(["--store", &store])
            .timeout(std::time::Duration::from_secs(60))
            .status()?;
        if !ping.is_success() {
            return request_error(format!("store probe failed for {store}"));
        }
        ui::result("store: ok");
        if ifd {
            let route = Route::Store(builder.clone());
            let probe = format!(
                ".#legacyPackages.{}.remoteIfdProbe",
                crate::support::nix::SYSTEM
            );
            let result = format!(
                ".#legacyPackages.{}.remoteIfdProbeResult",
                crate::support::nix::SYSTEM
            );
            let built = crate::support::nix::Invocation::flake("build", &probe)
                .arg("--no-link")
                .workdir(repo)
                .route(&route)?
                .status()?;
            if !built.is_success() {
                return request_error("IFD probe derivation failed to build");
            }
            let output = crate::support::nix::Invocation::flake("eval", &result)
                .raw()
                .offline()
                .workdir(repo)
                .route(&route)?
                .probe("the round trip is judged by the evaluated value")?;
            if !output.status.is_success()
                || String::from_utf8_lossy(&output.stdout).trim() != "ok"
            {
                return request_error(format!(
                    "IFD store round trip failed: {}",
                    output.stderr.trim()
                ));
            }
            ui::result("ifd: ok");
        }
    } else if ifd {
        return request_error(format!("remote {:?} has no store capability", builder.name));
    }
    Ok(CommandStatus::SUCCESS)
}

fn field(repo: &Path, remote: Option<&str>, field: BuilderField) -> Result<CommandStatus> {
    let builder = builder::load(repo, remote)?;
    let value = match field {
        BuilderField::Store => builder.store(),
        BuilderField::Builders => builder.builders(),
        BuilderField::Host => builder.host.clone(),
        BuilderField::Key => builder.key.display().to_string(),
    };
    ui::result(value);
    Ok(CommandStatus::SUCCESS)
}

const TEMPLATE: &str = r#"# Remotes shared by this developer's worktrees. `wasinix remote doctor`
# verifies an entry; `--on <name>` uses one.
#
# default = "ec2"
#
# [remotes.ec2]
# description = "what this machine is for"
# host = "user@host.example.com"
# key = "~/.ssh/id_ed25519"
# # ssh host key: base64 over the "type key" line (nix builders form) or the
# # raw line; "-" pins nothing and accepts the key on first connection
# host_key = "-"
# capabilities = ["builder", "store", "host"]
# capacity = 1
"#;

fn init() -> Result<CommandStatus> {
    let path = builder::config_path()?;
    if path.exists() {
        return request_error(format!("{} already exists", path.display()));
    }
    crate::support::fs::write(&path, TEMPLATE.as_bytes())?;
    ui::result(path.display());
    Ok(CommandStatus::SUCCESS)
}

pub(crate) fn run(command: RemoteCommand) -> Result<CommandStatus> {
    use crate::support::git::repo_root;
    match command {
        RemoteCommand::List { json } => list(&repo_root()?, json),
        RemoteCommand::Status { remote } => status(&repo_root()?, remote.as_deref()),
        RemoteCommand::Doctor { remote, ifd } => doctor(&repo_root()?, remote.as_deref(), ifd),
        RemoteCommand::Field { field: name, remote } => field(&repo_root()?, remote.as_deref(), name),
        RemoteCommand::Init => init(),
    }
}
