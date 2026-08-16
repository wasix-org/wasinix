use std::time::{SystemTime, UNIX_EPOCH};

pub fn unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock is before the unix epoch")
        .as_secs()
}

pub fn unix_nanos() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock is before the unix epoch")
        .as_nanos()
}

/// `HH:MM UTC` for a unix timestamp; comments and reports are edited in
/// place, so absolute wall-clock beats relative phrasing that goes stale.
pub fn wall_clock_utc(unix: u64) -> String {
    let minutes = (unix % 86_400) / 60;
    format!("{:02}:{:02} UTC", minutes / 60, minutes % 60)
}
