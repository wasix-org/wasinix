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

/// `YYYY-MM-DDTHH:MM:SSZ` as unix seconds. GitHub's run records use that one
/// shape, so anything else is None rather than a guess at what was meant.
pub fn parse_utc(text: &str) -> Option<u64> {
    let bytes = text.as_bytes();
    let punctuation = [
        (4, b'-'),
        (7, b'-'),
        (10, b'T'),
        (13, b':'),
        (16, b':'),
        (19, b'Z'),
    ];
    if bytes.len() != 20 || punctuation.iter().any(|&(at, sep)| bytes[at] != sep) {
        return None;
    }
    let field = |range: std::ops::Range<usize>| -> Option<i64> {
        text.get(range).and_then(|digits| digits.parse().ok())
    };
    let (year, month, day) = (field(0..4)?, field(5..7)?, field(8..10)?);
    let (hour, minute, second) = (field(11..13)?, field(14..16)?, field(17..19)?);
    // Days from civil: the year starts in March, which puts the leap day
    // last and makes the day-of-year a closed form.
    let shifted = year - i64::from(month <= 2);
    let era = shifted.div_euclid(400);
    let year_of_era = shifted - era * 400;
    let day_of_year = (153 * (month + if month > 2 { -3 } else { 9 }) + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    u64::try_from(days * 86_400 + hour * 3_600 + minute * 60 + second).ok()
}

/// `HH:MM UTC` for a unix timestamp; comments and reports are edited in
/// place, so absolute wall-clock beats relative phrasing that goes stale.
pub fn wall_clock_utc(unix: u64) -> String {
    let minutes = (unix % 86_400) / 60;
    format!("{:02}:{:02} UTC", minutes / 60, minutes % 60)
}
