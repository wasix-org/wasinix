//! The one spelling for each rendered quantity, shared by terminal, markdown,
//! and progress output.

/// 12 hex characters, safe on any input length.
pub fn short_rev(rev: &str) -> &str {
    let end = rev
        .char_indices()
        .nth(12)
        .map(|(index, _)| index)
        .unwrap_or(rev.len());
    &rev[..end]
}

/// `Nh Nm` above an hour, `Nm Ns` above a minute, `Ns` below.
pub fn duration(seconds: f64) -> String {
    let total = seconds.max(0.0).round() as u64;
    if total >= 3600 {
        format!("{}h {}m", total / 3600, (total % 3600) / 60)
    } else if total >= 60 {
        format!("{}m {}s", total / 60, total % 60)
    } else {
        format!("{total}s")
    }
}

/// The first few names with the remainder counted: `a, b, c +2`.
pub fn some<S: AsRef<str>>(names: &[S], shown: usize) -> String {
    let listed: Vec<&str> = names.iter().take(shown).map(AsRef::as_ref).collect();
    let more = names.len().saturating_sub(listed.len());
    if more > 0 {
        format!("{} +{more}", listed.join(", "))
    } else {
        listed.join(", ")
    }
}

/// Binary units, one decimal above KiB.
pub fn bytes(count: u64) -> String {
    const UNITS: [&str; 5] = ["B", "KiB", "MiB", "GiB", "TiB"];
    let mut value = count as f64;
    let mut unit = 0;
    while value >= 1024.0 && unit < UNITS.len() - 1 {
        value /= 1024.0;
        unit += 1;
    }
    if unit == 0 {
        format!("{count} B")
    } else {
        format!("{value:.1} {}", UNITS[unit])
    }
}
