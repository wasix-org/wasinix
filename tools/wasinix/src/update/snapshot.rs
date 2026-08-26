//! The tree-keyed update inputs Nix projects once: target declarations,
//! post-update hooks, served versions, and note versions. CI publishes this
//! view with its eval map, and update commands evaluate it only on a miss.

use std::path::Path;
use std::sync::mpsc::RecvTimeoutError;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::support::error::{Error, Result, request_error};
use crate::support::ui;
use crate::update::retention::Versions;

const SCHEMA: u64 = 2;
const HEARTBEAT: Duration = Duration::from_secs(10);

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Notes {
    pub ok: bool,
    pub value: Value,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub schema_version: u64,
    pub default_update_ownership: crate::update::targets::Ownership,
    pub update_scripts: Value,
    pub post_update_hooks: Value,
    pub served_versions: Versions,
    pub notes: Notes,
}

impl Snapshot {
    fn validate(self) -> Result<Self> {
        if self.schema_version != SCHEMA {
            return request_error(format!(
                "update snapshot schema {} is not the supported {SCHEMA}",
                self.schema_version
            ));
        }
        Ok(self)
    }
}

fn clean_tree(repo: &Path) -> Result<Option<String>> {
    if !crate::support::git::git(repo, &["status", "--porcelain"])?
        .trim()
        .is_empty()
    {
        return Ok(None);
    }
    Ok(Some(crate::support::git::git(
        repo,
        &["rev-parse", "HEAD^{tree}"],
    )?))
}

fn cached(repo: &Path, template: &str) -> Result<Option<Snapshot>> {
    let Some(tree) = clean_tree(repo)? else {
        ui::fact("update state", "working tree changed; evaluating");
        return Ok(None);
    };
    ui::fact("update state", format!("checking cached tree {tree}"));
    match crate::ci::baseline::fetch(&tree, template) {
        crate::ci::baseline::Fetch::Found(map) => match map.update_snapshot {
            Some(snapshot) => {
                ui::fact("update state", "reused cached evaluation");
                snapshot.validate().map(Some)
            }
            None => {
                ui::fact("update state", "cached evaluation has no update state");
                Ok(None)
            }
        },
        crate::ci::baseline::Fetch::Missing(reason) => {
            ui::fact("update state", format!("cache miss: {reason}"));
            Ok(None)
        }
    }
}

pub(crate) fn evaluate(repo: &Path) -> Result<Snapshot> {
    let started = Instant::now();
    ui::fact(
        "update state",
        "evaluating targets, hooks, and served versions",
    );
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let value = std::thread::scope(|scope| {
        scope.spawn(move || {
            let result = crate::support::nix::Invocation::flake(
                "eval",
                crate::support::nix::active_project_installable(
                    "internals.repository.updates.snapshot",
                ),
            )
            .json()
            .workdir(repo)
            .run_json("update state");
            let _ = sender.send(result);
        });
        loop {
            match receiver.recv_timeout(HEARTBEAT) {
                Ok(result) => break result,
                Err(RecvTimeoutError::Timeout) => ui::fact(
                    "update state",
                    format!(
                        "evaluating · running for {}",
                        crate::support::format::duration(started.elapsed().as_secs_f64())
                    ),
                ),
                Err(RecvTimeoutError::Disconnected) => {
                    break Err(Error::Failure("update evaluation stopped".into()));
                }
            }
        }
    })?;
    let snapshot: Snapshot = crate::support::json::from_value(value, "update state")?;
    ui::fact(
        "update state",
        format!(
            "evaluation ready · took {}",
            crate::support::format::duration(started.elapsed().as_secs_f64())
        ),
    );
    snapshot.validate()
}

pub fn load(repo: &Path) -> Result<Snapshot> {
    match cached(repo, &crate::ci::baseline::map_url_template())? {
        Some(snapshot) => Ok(snapshot),
        None => evaluate(repo),
    }
}

#[cfg(test)]
mod tests {
    use super::Snapshot;

    fn snapshot(schema_version: u64) -> Snapshot {
        Snapshot {
            schema_version,
            default_update_ownership: Default::default(),
            update_scripts: serde_json::json!({}),
            post_update_hooks: serde_json::json!({}),
            served_versions: Default::default(),
            notes: super::Notes {
                ok: true,
                value: serde_json::json!({}),
            },
        }
    }

    #[test]
    fn cached_update_state_rejects_an_unknown_schema() {
        assert!(snapshot(2).validate().is_ok());
        assert!(snapshot(1).validate().is_err());
    }

    #[test]
    fn a_clean_tree_reuses_its_published_update_state() {
        let scratch = crate::support::fs::Scratch::create("wasinix-update-cache-test").unwrap();
        let repo = scratch.path().join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        crate::support::git::git(&repo, &["init", "--initial-branch=main"]).unwrap();
        crate::support::git::git(&repo, &["config", "user.name", "Test"]).unwrap();
        crate::support::git::git(&repo, &["config", "user.email", "test@example.invalid"]).unwrap();
        std::fs::write(repo.join("file"), "content\n").unwrap();
        crate::support::git::git(&repo, &["add", "file"]).unwrap();
        crate::support::git::git(&repo, &["commit", "-m", "fixture"]).unwrap();
        let tree = crate::support::git::git(&repo, &["rev-parse", "HEAD^{tree}"]).unwrap();
        let job = crate::support::atoms::JobAddr("checks.fixture".into());
        let published = crate::ci::evalmap::EvalMap {
            update_snapshot: Some(snapshot(1)),
            status: Some([(job.clone(), crate::support::atoms::JobStatus::Success)].into()),
            coverage: vec![job],
            ..Default::default()
        };
        let maps = crate::ci::prepare::maps_dir(scratch.path());
        std::fs::create_dir_all(&maps).unwrap();
        crate::support::schema::write(&maps.join(format!("{tree}.json")), &published).unwrap();
        let cached = super::cached(&repo, &format!("{}/{{tree}}.json", maps.display()))
            .unwrap()
            .unwrap();
        assert_eq!(cached, snapshot(1));
    }
}
