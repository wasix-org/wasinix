//! Where nix work runs. The one placement axis (`--on local | <remote> |
//! <remote>:<route>`) resolves here, once, into a Route every execution site
//! consumes; nothing downstream carries a second local/remote flag.

use std::path::Path;
use std::process::Command;
use std::time::Duration;

use crate::nix::builder::{self, Builder, Capability, Lease, RouteKind};
use crate::support::error::{Error, Result, request_error};

pub const DEFAULT_LOCAL_EVAL_WORKERS: usize = 2;
pub const DEFAULT_REMOTE_EVAL_WORKERS: usize = 2;
pub const DEFAULT_LOCAL_EVAL_MEMORY: usize = 8192;
pub const DEFAULT_REMOTE_EVAL_MEMORY: usize = 16384;
pub const DEFAULT_EVAL_TIMEOUT_SECONDS: u64 = 600;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EvaluationLimits {
    pub workers: usize,
    pub memory: usize,
    pub timeout: Duration,
}

impl EvaluationLimits {
    pub fn local() -> Result<Self> {
        let profile = builder::local_profile()?;
        Ok(Self {
            workers: crate::support::env::eval_workers()?
                .or(profile.eval_workers)
                .unwrap_or(DEFAULT_LOCAL_EVAL_WORKERS),
            memory: crate::support::env::eval_memory()?
                .or(profile.eval_memory)
                .unwrap_or(DEFAULT_LOCAL_EVAL_MEMORY),
            timeout: evaluation_timeout()?,
        })
    }

    pub fn configured(
        builder: &Builder,
        default_workers: usize,
        default_memory: usize,
    ) -> Result<Self> {
        Ok(Self {
            workers: crate::support::env::eval_workers()?
                .or(builder.eval_workers)
                .unwrap_or(default_workers),
            memory: crate::support::env::eval_memory()?
                .or(builder.eval_memory)
                .unwrap_or(default_memory),
            timeout: evaluation_timeout()?,
        })
    }
}

pub fn default_eval_workers(route: RouteKind) -> usize {
    match route {
        RouteKind::Host => DEFAULT_REMOTE_EVAL_WORKERS,
        RouteKind::Local | RouteKind::Builder | RouteKind::Store => DEFAULT_LOCAL_EVAL_WORKERS,
    }
}

pub fn evaluation_timeout() -> Result<Duration> {
    Ok(crate::support::env::eval_timeout()?
        .unwrap_or(Duration::from_secs(DEFAULT_EVAL_TIMEOUT_SECONDS)))
}

pub fn max_jobs(default: usize) -> Result<usize> {
    Ok(crate::support::env::max_jobs()?
        .or(builder::local_profile()?.max_jobs)
        .unwrap_or(default))
}

#[derive(Debug, Clone)]
pub enum Route {
    Local(EvaluationLimits),
    Builder(Builder),
    Store(Builder),
    Host(Builder),
}

impl Route {
    pub fn local() -> Result<Route> {
        Ok(Route::Local(EvaluationLimits::local()?))
    }

    /// Resolve `--on`: `local`, a remote name, or `<remote>:<route>`. Absent
    /// means the configured default remote on its default route.
    pub fn from_on(repo: &Path, on: Option<&str>) -> Result<Route> {
        let (selected, requested) = match on {
            None => (None, None),
            Some("local") => return Route::local(),
            Some(spec) => match spec.split_once(':') {
                Some((name, route)) => (Some(name), Some(RouteKind::parse(route)?)),
                None => (Some(spec), None),
            },
        };
        if requested == Some(RouteKind::Local) {
            return request_error("a remote cannot route local; pass `--on local` to run here");
        }
        let builder = builder::load(repo, selected)?;
        let kind = requested
            .or(builder.route)
            .unwrap_or_else(|| builder.default_route());
        let capability = match kind {
            RouteKind::Builder => Capability::Builder,
            RouteKind::Store => Capability::Store,
            RouteKind::Host => Capability::Host,
            RouteKind::Local => {
                return request_error(format!(
                    "remote {:?} cannot use local as its route",
                    builder.name
                ));
            }
        };
        if !builder.supports(capability) {
            return request_error(format!(
                "remote {:?} does not provide the {} route",
                builder.name,
                kind.as_str()
            ));
        }
        Ok(match kind {
            RouteKind::Builder => Route::Builder(builder),
            RouteKind::Store => Route::Store(builder),
            RouteKind::Host => Route::Host(builder),
            RouteKind::Local => unreachable!("rejected above"),
        })
    }

    pub fn limits(&self) -> Result<EvaluationLimits> {
        match self {
            Route::Local(limits) => Ok(*limits),
            Route::Builder(builder) | Route::Store(builder) => EvaluationLimits::configured(
                builder,
                default_eval_workers(RouteKind::Builder),
                DEFAULT_LOCAL_EVAL_MEMORY,
            ),
            Route::Host(builder) => EvaluationLimits::configured(
                builder,
                default_eval_workers(RouteKind::Host),
                DEFAULT_REMOTE_EVAL_MEMORY,
            ),
        }
    }

    pub fn builder(&self) -> Option<&Builder> {
        match self {
            Route::Local(_) => None,
            Route::Builder(builder) | Route::Store(builder) | Route::Host(builder) => Some(builder),
        }
    }

    pub fn store(&self) -> Option<String> {
        match self {
            Route::Store(builder) => Some(builder.store()),
            _ => None,
        }
    }

    pub fn acquire(&self) -> Result<Option<Lease>> {
        if matches!(self, Route::Local(_)) {
            return match builder::local_profile()?.capacity {
                Some(capacity) => builder::acquire_local(capacity).map(Some),
                None => Ok(None),
            };
        }
        self.builder().map(builder::acquire).transpose()
    }

    /// A host route executes whole commands on the host; asking it to
    /// configure a caller-side nix invocation is a wiring mistake, reported
    /// rather than assumed away.
    fn no_host(&self, what: &str) -> Result<()> {
        if matches!(self, Route::Host(_)) {
            return Err(Error::Failure(format!(
                "a host route reached {what}; host work runs through the remote runner"
            )));
        }
        Ok(())
    }

    pub fn configure_nix(&self, command: &mut Command) -> Result<()> {
        self.no_host("a nix invocation")?;
        if let Route::Store(builder) = self {
            command.args(["--store", &builder.store(), "--eval-store", "auto"]);
        }
        command.args(self.build_nix_options());
        Ok(())
    }

    pub fn configure_eval_jobs(&self, command: &mut Command) -> Result<()> {
        self.no_host("nix-eval-jobs")?;
        command.args(["--eval-store", "auto"]);
        if let Route::Store(builder) = self {
            command.args(["--option", "store", &builder.store()]);
        }
        command.args(self.build_nix_options());
        Ok(())
    }

    pub fn build_nix_options(&self) -> Vec<String> {
        let mut options = Vec::new();
        match self {
            Route::Local(_) => {
                options.extend(["--option".into(), "builders".into(), String::new()]);
            }
            Route::Builder(builder) => {
                options.extend([
                    "--option".into(),
                    "builders".into(),
                    builder.builders(),
                    "--option".into(),
                    "max-jobs".into(),
                    "0".into(),
                    "--option".into(),
                    "builders-use-substitutes".into(),
                    "true".into(),
                ]);
                options.extend(builder.nix_options());
            }
            Route::Store(builder) => options.extend(builder.nix_options()),
            Route::Host(_) => {}
        }
        options
    }
}
