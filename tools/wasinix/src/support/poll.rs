//! The one polling loop: fixed interval, optional deadline, bounded
//! consecutive failures, so "lost contact" means the same thing everywhere.

use std::time::{Duration, Instant};

use crate::support::error::{Error, Result};

pub enum Poll<T> {
    Pending,
    Ready(T),
}

pub struct Options {
    pub interval: Duration,
    pub deadline: Option<Duration>,
    /// Consecutive probe errors tolerated before the loop gives up with the
    /// last error.
    pub max_consecutive_failures: u32,
}

pub fn until<T>(options: Options, mut probe: impl FnMut() -> Result<Poll<T>>) -> Result<T> {
    let started = Instant::now();
    let mut failures: u32 = 0;
    loop {
        match probe() {
            Ok(Poll::Ready(value)) => return Ok(value),
            Ok(Poll::Pending) => failures = 0,
            Err(error) => {
                failures += 1;
                if failures > options.max_consecutive_failures {
                    return Err(error);
                }
            }
        }
        if let Some(deadline) = options.deadline {
            if started.elapsed() >= deadline {
                return Err(Error::Failure(format!(
                    "timed out after {}",
                    crate::support::format::duration(deadline.as_secs_f64())
                )));
            }
        }
        std::thread::sleep(options.interval);
    }
}
