//! How an argument names a thing.
//!
//! There is one address space: the flake attr path, rooted at
//! `legacyPackages.<system>` (or at `inputs.` for a flake input). Every command
//! takes addresses from it, so an argument is always something you can paste
//! after `nix build .#`.
//!
//! ```text
//! packagesByProfile.eh.zlib   full      the path itself
//! eh.zlib                     suffix    leading segments dropped, must reach the leaf
//! packagesByProfile.zlib      axis-free the variant segment dropped: every profile
//! packagesByProfile.*.zl*     glob      `*` matches in one segment, never across a dot
//! wasmerPackages."py3.14"   quoted      a segment holding a dot, spelled as Nix spells it
//! numpy@2.0.0               versioned   `@` attaches a version to any of the above
//! ```
//!
//! A command declares its own domain: the addresses it can act on. That is why
//! there are no namespace prefixes. `pin:` was never a root anyway, since pins
//! live at `toolchain.libc`, `pythonWheels.py313.ddtrace` and `inputs.nixpkgs`;
//! "what the update driver owns" is a property of the command, not of the name.

use std::collections::BTreeMap;

use crate::support::error::{request_error, Result};

/// Split an address into segments, honouring the quoting Nix itself uses for a
/// segment that holds a dot (`wasmerPackages."python3.14"`).
pub fn split(address: &str) -> Result<Vec<String>> {
    let mut segments = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut chars = address.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '"' => quoted = !quoted,
            '.' if !quoted => {
                if current.is_empty() {
                    return request_error(format!("{address:?}: empty path segment"));
                }
                segments.push(std::mem::take(&mut current));
            }
            _ => current.push(c),
        }
        if chars.peek().is_none() && quoted {
            return request_error(format!("{address:?}: unbalanced quote"));
        }
    }
    if current.is_empty() {
        return request_error(format!("{address:?}: empty path segment"));
    }
    segments.push(current);
    Ok(segments)
}

/// The inverse of `split`, quoting a segment that needs it.
pub fn render(segments: &[String]) -> String {
    segments
        .iter()
        .map(|segment| {
            if segment.contains('.') {
                format!("\"{segment}\"")
            } else {
                segment.clone()
            }
        })
        .collect::<Vec<_>>()
        .join(".")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Spec {
    pub segments: Vec<String>,
    /// What followed `@`: a version, or for a command that asks for a source
    /// revision, the revision.
    pub value: Option<String>,
}

impl Spec {
    pub fn is_glob(&self) -> bool {
        self.segments
            .iter()
            .any(|segment| segment.contains(['*', '?', '[']))
    }

    pub fn render(&self) -> String {
        match &self.value {
            Some(value) => format!("{}@{value}", render(&self.segments)),
            None => render(&self.segments),
        }
    }
}

/// Parse `<address>[@<value>]`. The split is at the first `@`: an address never
/// holds one, and a value may, as `github:OWNER/REPO@SHA` does.
pub fn parse(spec: &str) -> Result<Spec> {
    let (address, value) = match spec.split_once('@') {
        Some((address, value)) if !address.is_empty() && !value.is_empty() => {
            (address, Some(value.to_string()))
        }
        Some(_) => return request_error(format!("{spec:?}: expected address@value")),
        None => (spec, None),
    };
    Ok(Spec {
        segments: split(address)?,
        value,
    })
}

/// Roots whose second segment is a build variant rather than part of what the
/// thing is: the profile in `packagesByProfile.<profile>.<name>`, the
/// interpreter in `pythonWheels.<interpreter>.<name>`. The values themselves
/// are not restated here; only which segment holds them.
pub const VARIANT_ROOTS: [&str; 2] = ["packagesByProfile", "pythonWheels"];

/// Which segment of a path a caller may leave out, if any.
pub fn axis_of(path: &[String]) -> Option<usize> {
    (path.len() > 2 && VARIANT_ROOTS.contains(&path[0].as_str())).then_some(1)
}

#[derive(Debug, Clone)]
struct Entry {
    path: Vec<String>,
    /// A segment the caller may leave out because it is a build variant: the
    /// profile in `packagesByProfile.<profile>.<name>`, the interpreter in
    /// `pythonWheels.<interpreter>.<name>`. Omitting it means all of them.
    axis: Option<usize>,
    /// Names this entry also answers to, for a thing the repo calls something
    /// other than its leaf: a CLI's overlay attr beside its webc name.
    aliases: Vec<String>,
    /// What the command keys its own data by.
    key: String,
}

impl Entry {
    /// The structural addresses that name this entry: the path, the path
    /// without its variant segment, and every suffix of both that still
    /// reaches the leaf. Aliases are matched separately, since an alias hit
    /// outranks a suffix hit when a name is claimed by both.
    fn path_forms(&self) -> Vec<Vec<&str>> {
        fn suffixes<'a>(path: &[&'a str], forms: &mut Vec<Vec<&'a str>>) {
            for start in 0..path.len() {
                forms.push(path[start..].to_vec());
            }
        }
        let full: Vec<&str> = self.path.iter().map(String::as_str).collect();
        let mut forms: Vec<Vec<&str>> = Vec::new();
        suffixes(&full, &mut forms);
        if let Some(axis) = self.axis {
            let mut without = full.clone();
            without.remove(axis);
            suffixes(&without, &mut forms);
        }
        forms
    }

    /// What makes this entry a distinct thing rather than one build of it.
    /// Matches that differ only in their variant segment are one answer; any
    /// other difference is an ambiguity the caller has to resolve.
    fn identity(&self) -> String {
        let mut path = self.path.clone();
        if let Some(axis) = self.axis {
            path.remove(axis);
        }
        render(&path)
    }
}

/// The addresses one command can act on.
#[derive(Debug, Clone)]
pub struct Domain {
    entries: Vec<Entry>,
    /// Where the caller can see the whole list, quoted when nothing matches.
    hint: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub path: Vec<String>,
    /// The name the command's own data is keyed by.
    pub key: String,
    pub value: Option<String>,
}

impl Resolved {
    pub fn address(&self) -> String {
        render(&self.path)
    }
}

impl Domain {
    pub fn new(hint: impl Into<String>) -> Domain {
        Domain {
            entries: Vec::new(),
            hint: hint.into(),
        }
    }

    /// Segments given directly, for a name the repo spells with a dot in it
    /// (`wasmerPackages."python3.14"`), which no split of a flat string
    /// recovers.
    pub fn add_path(
        &mut self,
        path: Vec<String>,
        key: &str,
        axis: Option<usize>,
        aliases: Vec<String>,
    ) -> &mut Domain {
        self.entries.push(Entry {
            path,
            axis,
            aliases,
            key: key.to_string(),
        });
        self
    }

    /// Every entry a spec names, with whether it was named by its declared
    /// alias rather than a structural address.
    fn matches(&self, spec: &Spec) -> Vec<(&Entry, bool)> {
        let glob = spec.is_glob();
        // An unquoted spelling loses which dots were separators: a flattened
        // CI job name, or a dotted leaf like `jq-1.6.0` typed bare at a
        // shell. The joined form is accepted against every suffix form and
        // alias, so naming a thing exactly never requires quoting.
        let flat = spec.segments.join(".");
        let segment_matches = |segment: &str, wanted: &str| {
            if glob {
                matches_glob(wanted, segment)
            } else {
                segment == wanted
            }
        };
        self.entries
            .iter()
            .filter_map(|entry| {
                let by_alias = (spec.segments.len() == 1
                    && entry
                        .aliases
                        .iter()
                        .any(|alias| segment_matches(alias, &spec.segments[0])))
                    || (!glob && entry.aliases.contains(&flat));
                let by_path = entry.path_forms().into_iter().any(|form| {
                    (!glob && form.join(".") == flat)
                        || (form.len() == spec.segments.len()
                            && form
                                .iter()
                                .zip(&spec.segments)
                                .all(|(segment, wanted)| segment_matches(segment, wanted)))
                });
                (by_alias || by_path).then_some((entry, by_alias))
            })
            .collect()
    }

    /// The closest addresses to a spec nothing matched, so the error hands
    /// back something to paste rather than only naming the list.
    fn nearest(&self, spec: &Spec) -> Vec<String> {
        let wanted = spec
            .segments
            .last()
            .map(|leaf| leaf.replace(['*', '?'], "").to_ascii_lowercase())
            .unwrap_or_default();
        if wanted.is_empty() {
            return Vec::new();
        }
        let mut scored: Vec<(usize, String)> = Vec::new();
        for entry in &self.entries {
            let identity = entry.identity();
            let leaf = entry
                .path
                .last()
                .map(|leaf| leaf.to_ascii_lowercase())
                .unwrap_or_default();
            let score = if leaf == wanted {
                wanted.len() + 2
            } else if leaf.contains(&wanted) || wanted.contains(&leaf) {
                wanted.len().min(leaf.len()) + 1
            } else {
                leaf.bytes()
                    .zip(wanted.bytes())
                    .take_while(|(a, b)| a == b)
                    .count()
            };
            if score >= 3 {
                scored.push((score, identity));
            }
        }
        scored.sort_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
        scored.dedup_by(|a, b| a.1 == b.1);
        scored.into_iter().take(3).map(|(_, identity)| identity).collect()
    }

    /// Every entry the spec names. A glob fans out; an exact address that names
    /// two different things is an error that prints both, so the fix is always
    /// to copy one back.
    pub fn resolve(&self, spec: &Spec) -> Result<Vec<Resolved>> {
        let mut hits = self.matches(spec);
        if hits.is_empty() {
            let nearest = self.nearest(spec);
            let suggestion = if nearest.is_empty() {
                String::new()
            } else {
                format!("; nearest: {}", nearest.join(", "))
            };
            return request_error(format!(
                "{}: no match in {}{suggestion}",
                spec.render(),
                self.hint
            ));
        }
        if !spec.is_glob() {
            let identities = |hits: &[(&Entry, bool)]| {
                let mut seen: BTreeMap<String, ()> = BTreeMap::new();
                for (entry, _) in hits {
                    seen.entry(entry.identity()).or_insert(());
                }
                seen
            };
            // A declared name outranks another entry's structural suffix:
            // naming a thing by what it is called must not go ambiguous
            // because someone else's address happens to end the same way.
            if identities(&hits).len() > 1 {
                let by_alias: Vec<(&Entry, bool)> = hits
                    .iter()
                    .copied()
                    .filter(|(_, by_alias)| *by_alias)
                    .collect();
                if identities(&by_alias).len() == 1 {
                    hits = by_alias;
                }
            }
            let identities = identities(&hits);
            if identities.len() > 1 {
                let options: Vec<String> = identities.keys().cloned().collect();
                return request_error(format!(
                    "{}: ambiguous, name one of {}",
                    spec.render(),
                    options.join(", ")
                ));
            }
        }
        let mut resolved: Vec<Resolved> = Vec::new();
        for (entry, _) in hits {
            if resolved.iter().any(|done| done.key == entry.key) {
                continue;
            }
            resolved.push(Resolved {
                path: entry.path.clone(),
                key: entry.key.clone(),
                value: spec.value.clone(),
            });
        }
        Ok(resolved)
    }
}

/// Resolve several specs, keeping the caller's order and dropping repeats.
pub fn resolve_all(domain: &Domain, specs: &[String]) -> Result<Vec<Resolved>> {
    let mut out: Vec<Resolved> = Vec::new();
    for spec in specs {
        for resolved in domain.resolve(&parse(spec)?)? {
            if !out.contains(&resolved) {
                out.push(resolved);
            }
        }
    }
    Ok(out)
}

/// fnmatch within one segment: `*` and `?` any run, `[...]` a class. A segment
/// never holds a dot, so no pattern here can cross one.
pub fn matches_glob(pattern: &str, value: &str) -> bool {
    fn walk(pattern: &[u8], value: &[u8]) -> bool {
        match pattern.first() {
            None => value.is_empty(),
            Some(b'*') => (0..=value.len()).any(|split| walk(&pattern[1..], &value[split..])),
            Some(b'?') => !value.is_empty() && walk(&pattern[1..], &value[1..]),
            Some(b'[') => {
                let Some(end) = pattern.iter().position(|byte| *byte == b']') else {
                    return false;
                };
                let (negated, class) = match pattern[1] {
                    b'!' | b'^' => (true, &pattern[2..end]),
                    _ => (false, &pattern[1..end]),
                };
                let Some(head) = value.first() else {
                    return false;
                };
                let mut hit = false;
                let mut index = 0;
                while index < class.len() {
                    if index + 2 < class.len() && class[index + 1] == b'-' {
                        hit |= (class[index]..=class[index + 2]).contains(head);
                        index += 3;
                    } else {
                        hit |= class[index] == *head;
                        index += 1;
                    }
                }
                hit != negated && walk(&pattern[end + 1..], &value[1..])
            }
            Some(byte) => value.first() == Some(byte) && walk(&pattern[1..], &value[1..]),
        }
    }
    walk(pattern.as_bytes(), value.as_bytes())
}

/// How a source is named, in the one spelling every grammar takes: a bare
/// release the update script resolves, an exact commit, or a tag resolved to
/// the commit it points at.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceSpec<'a> {
    Release(&'a str),
    Revision(&'a str),
    Tag(&'a str),
}

/// Parse a source spelling. A scheme naming nothing is an error, never an
/// empty value, and an unknown scheme is a release: a version may contain a
/// colon in principle, and guessing otherwise would refuse valid pins.
pub fn source_spec(value: &str) -> Result<SourceSpec<'_>> {
    let scheme = |prefix: &str| -> Result<Option<&str>> {
        match value.strip_prefix(prefix) {
            Some("") => crate::support::error::request_error(format!(
                "{prefix} names no {}",
                prefix.trim_end_matches(':')
            )),
            other => Ok(other),
        }
    };
    if let Some(rev) = scheme("rev:")? {
        return Ok(SourceSpec::Revision(rev));
    }
    if let Some(tag) = scheme("tag:")? {
        return Ok(SourceSpec::Tag(tag));
    }
    Ok(SourceSpec::Release(value))
}

/// One attribute segment as an installable or address spells it: quoted
/// whenever the plain spelling would not survive a re-split, refusing a
/// name that would escape the quotes.
pub fn quoted_attr(name: &str) -> Result<String> {
    if name.is_empty() || name.contains(['"', '\\', '$']) {
        return crate::support::error::request_error(format!(
            "{name:?} cannot be spelled as a nix attribute"
        ));
    }
    Ok(if name.contains('.') {
        format!("\"{name}\"")
    } else {
        name.to_string()
    })
}
