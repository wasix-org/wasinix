use std::path::PathBuf;
use std::time::Instant;

use crate::support::error::Result;

#[derive(
    Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, serde::Serialize, serde::Deserialize,
)]
#[serde(rename_all = "kebab-case")]
pub enum Phase {
    Backend,
    Changelog,
    Reevaluation,
    FormatCommit,
    Retention,
    Pruning,
    Hooks,
    PullRequest,
}

impl Phase {
    pub const ALL: [Phase; 8] = [
        Phase::Backend,
        Phase::Changelog,
        Phase::Reevaluation,
        Phase::FormatCommit,
        Phase::Retention,
        Phase::Pruning,
        Phase::Hooks,
        Phase::PullRequest,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Phase::Backend => "updater",
            Phase::Changelog => "changelog",
            Phase::Reevaluation => "reevaluation",
            Phase::FormatCommit => "format/commit",
            Phase::Retention => "retention",
            Phase::Pruning => "pruning",
            Phase::Hooks => "hooks",
            Phase::PullRequest => "pull request",
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PhaseTiming {
    pub phase: Phase,
    pub duration_milliseconds: u64,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Timings {
    pub phases: Vec<PhaseTiming>,
}

impl crate::support::schema::Document for Timings {
    const KIND: &'static str = "updateTimings";
    const SCHEMA: u32 = 1;
}

pub struct Recorder {
    timings: Timings,
    path: Option<PathBuf>,
}

impl Recorder {
    pub fn new(path: Option<PathBuf>) -> Recorder {
        Recorder {
            timings: Timings::default(),
            path,
        }
    }

    pub fn measure<T>(&mut self, phase: Phase, operation: impl FnOnce() -> Result<T>) -> Result<T> {
        let started = Instant::now();
        let result = operation();
        let elapsed = started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64;
        match self
            .timings
            .phases
            .iter_mut()
            .find(|timing| timing.phase == phase)
        {
            Some(timing) => timing.duration_milliseconds += elapsed,
            None => self.timings.phases.push(PhaseTiming {
                phase,
                duration_milliseconds: elapsed,
            }),
        }
        result
    }

    pub fn finish(mut self) -> Result<()> {
        self.timings.phases.sort_by_key(|timing| timing.phase);
        if let Some(path) = self.path {
            crate::support::schema::write(&path, &self.timings)?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::support::error::request_error;

    #[test]
    fn sidecar_aggregates_named_phases_even_when_a_phase_fails() {
        let scratch = crate::support::fs::Scratch::create("update-timings").unwrap();
        let path = scratch.path().join("timings.json");
        let mut recorder = Recorder::new(Some(path.clone()));
        recorder.measure(Phase::Backend, || Ok(())).unwrap();
        recorder.measure(Phase::Backend, || Ok(())).unwrap();
        let failure: Result<()> = recorder.measure(Phase::Hooks, || request_error("failed hook"));
        assert!(failure.is_err());
        recorder.finish().unwrap();

        let timings: Timings = crate::support::schema::read(&path).unwrap();
        assert_eq!(timings.phases.len(), 2);
        assert_eq!(timings.phases[0].phase, Phase::Backend);
        assert_eq!(timings.phases[1].phase, Phase::Hooks);
    }
}
