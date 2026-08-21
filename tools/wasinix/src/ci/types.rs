//! The wire contracts between CI stages. A case's source is generic over its
//! stage so a parsed reference and a resolved revision cannot be confused:
//! resolving is the only way to obtain the second from the first, and only the
//! second can be built.

use serde::{Deserialize, Serialize};

use crate::support::atoms::{BlockedPolicy, Rev};
use crate::support::schema::Document;

/// A case as written by the caller: a ref that still has to be resolved.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RefSource {
    #[serde(rename = "ref")]
    pub reference: String,
}

/// A case pinned to one commit, optionally with a materialization patch.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RevSource {
    pub rev: Rev,
    /// Digest of the materialization patch, once the case has been prepared.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub patch: Option<String>,
    /// Whether the caller's uncommitted changes are part of this case.
    pub working_tree: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SelectorKind {
    Set,
    Job,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Selector {
    pub kind: SelectorKind,
    pub name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum OverrideKind {
    Release,
    Revision,
    /// A tag, resolved to its commit by the update grammar that applies it.
    Tag,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Override {
    pub target: String,
    pub kind: OverrideKind,
    pub value: String,
    /// Set when the override came from `--from-pr` rather than `--with`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub origin: Option<String>,
}

/// The set of jobs a build case covers.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum SetName {
    Core,
    Packages,
    Python,
}

impl SetName {
    /// Scheduling order. Core builds the toolchain everything else needs.
    pub const ORDER: [SetName; 3] = [SetName::Core, SetName::Packages, SetName::Python];

    pub fn as_str(self) -> &'static str {
        match self {
            SetName::Core => "core",
            SetName::Packages => "packages",
            SetName::Python => "python",
        }
    }

    pub fn parse(value: &str) -> Option<SetName> {
        match value {
            "core" => Some(SetName::Core),
            "packages" => Some(SetName::Packages),
            "python" => Some(SetName::Python),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Build<S> {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub case_id: Option<String>,
    pub source: S,
    pub selectors: Vec<Selector>,
    /// CI capabilities enabled for this case. A job runs only when all of its
    /// declared tags are present.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub enabled_tags: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub overrides: Vec<Override>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_pr: Option<String>,
    /// Where the case runs: `local`, a remote name, or `<remote>:<route>`.
    /// Absent means the configured default. Placement never contributes to a
    /// case's identity.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Spot<S> {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub case_id: Option<String>,
    pub source: S,
    pub targets: Vec<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub from_source: Vec<String>,
    /// Cached revision the spot build layers on top of.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub overrides: Vec<Override>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_pr: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub on: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
#[serde(bound(
    serialize = "S: Serialize",
    deserialize = "S: serde::de::DeserializeOwned"
))]
pub struct Diff<S> {
    pub baseline: String,
    pub content_diff: bool,
    pub cases: Vec<Case<S>>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Case<S> {
    Build(Build<S>),
    Spot(Spot<S>),
}

impl<S: Serialize> Serialize for Case<S> {
    fn serialize<T>(&self, serializer: T) -> Result<T::Ok, T::Error>
    where
        T: serde::Serializer,
    {
        let (action, value) = match self {
            Case::Build(case) => ("build", serde_json::to_value(case)),
            Case::Spot(case) => ("spot", serde_json::to_value(case)),
        };
        let mut value = value.map_err(serde::ser::Error::custom)?;
        value
            .as_object_mut()
            .ok_or_else(|| serde::ser::Error::custom("case is not an object"))?
            .insert("action".into(), serde_json::Value::String(action.into()));
        value.serialize(serializer)
    }
}

impl<'de, S: serde::de::DeserializeOwned> Deserialize<'de> for Case<S> {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let mut value = serde_json::Value::deserialize(deserializer)?;
        let action = value
            .as_object_mut()
            .and_then(|map| map.remove("action"))
            .and_then(|value| value.as_str().map(str::to_string))
            .ok_or_else(|| serde::de::Error::custom("diff case has no action"))?;
        match action.as_str() {
            "build" => serde_json::from_value(value)
                .map(Case::Build)
                .map_err(serde::de::Error::custom),
            "spot" => serde_json::from_value(value)
                .map(Case::Spot)
                .map_err(serde::de::Error::custom),
            _ => Err(serde::de::Error::custom(format!(
                "unknown diff case action {action:?}"
            ))),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "lowercase")]
#[serde(bound(
    serialize = "S: Serialize",
    deserialize = "S: serde::de::DeserializeOwned"
))]
pub enum RequestAction<S> {
    Build(Build<S>),
    Spot(Spot<S>),
    Diff(Diff<S>),
}

/// A whole request. Policy sits outside the cases so the cases in a diff
/// cannot disagree about the run's outcome.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(bound(
    serialize = "S: Serialize",
    deserialize = "S: serde::de::DeserializeOwned"
))]
pub struct Request<S> {
    pub blocked: BlockedPolicy,
    #[serde(flatten)]
    pub action: RequestAction<S>,
}

pub type ParsedRequest = Request<RefSource>;
pub type ResolvedRequest = Request<RevSource>;

impl Document for ParsedRequest {
    const KIND: &'static str = "request";
    const SCHEMA: u32 = 2;
}

impl Document for ResolvedRequest {
    const KIND: &'static str = "request";
    const SCHEMA: u32 = 2;
}

impl<S> Request<S> {
    pub fn build(build: Build<S>, blocked: BlockedPolicy) -> Request<S> {
        Request {
            blocked,
            action: RequestAction::Build(build),
        }
    }

    pub fn spot(spot: Spot<S>, blocked: BlockedPolicy) -> Request<S> {
        Request {
            blocked,
            action: RequestAction::Spot(spot),
        }
    }

    pub fn diff(diff: Diff<S>, blocked: BlockedPolicy) -> Request<S> {
        Request {
            blocked,
            action: RequestAction::Diff(diff),
        }
    }

    pub fn is_diff(&self) -> bool {
        matches!(self.action, RequestAction::Diff(_))
    }

    /// Rewrite every case's placement. Shipping a request to a host consumes
    /// the placement axis, and placement never contributes to identity.
    pub fn set_placement(&mut self, on: Option<String>) {
        let cases: Vec<&mut Option<String>> = match &mut self.action {
            RequestAction::Build(build) => vec![&mut build.on],
            RequestAction::Spot(spot) => vec![&mut spot.on],
            RequestAction::Diff(diff) => diff
                .cases
                .iter_mut()
                .map(|case| match case {
                    Case::Build(build) => &mut build.on,
                    Case::Spot(spot) => &mut spot.on,
                })
                .collect(),
        };
        for case in cases {
            *case = on.clone();
        }
    }

    /// Fill an unset `--from-pr`: in a pull-request context a bare command
    /// means "this PR", never the default branch.
    pub fn default_from_pr(&mut self) {
        let cases: Vec<&mut Option<String>> = match &mut self.action {
            RequestAction::Build(build) => vec![&mut build.from_pr],
            RequestAction::Spot(spot) => vec![&mut spot.from_pr],
            RequestAction::Diff(diff) => diff
                .cases
                .iter_mut()
                .map(|case| match case {
                    Case::Build(build) => &mut build.from_pr,
                    Case::Spot(spot) => &mut spot.from_pr,
                })
                .collect(),
        };
        for case in cases {
            if case.is_none() {
                *case = Some("current".to_string());
            }
        }
    }

    /// Every case, in scheduling order. A build or spot request is one case.
    pub fn cases(&self) -> Vec<CaseRef<'_, S>> {
        match &self.action {
            RequestAction::Build(build) => vec![CaseRef::Build(build)],
            RequestAction::Spot(spot) => vec![CaseRef::Spot(spot)],
            RequestAction::Diff(diff) => diff.cases.iter().map(Case::as_ref).collect(),
        }
    }
}

/// A borrowed case. Spot and build cases differ in what they can be asked to
/// do, so the phases that only apply to one of them take this rather than a
/// stringly-typed action.
#[derive(Debug)]
pub enum CaseRef<'a, S> {
    Build(&'a Build<S>),
    Spot(&'a Spot<S>),
}

// A borrowed handle is always copyable; deriving would demand `S: Copy`.
impl<S> Clone for CaseRef<'_, S> {
    fn clone(&self) -> Self {
        *self
    }
}

impl<S> Copy for CaseRef<'_, S> {}

impl<'a, S> CaseRef<'a, S> {
    pub fn case_id(&self) -> &'a str {
        let id = match self {
            CaseRef::Build(build) => build.case_id.as_deref(),
            CaseRef::Spot(spot) => spot.case_id.as_deref(),
        };
        id.unwrap_or("case")
    }

    pub fn source(&self) -> &'a S {
        match self {
            CaseRef::Build(build) => &build.source,
            CaseRef::Spot(spot) => &spot.source,
        }
    }

    pub fn overrides(&self) -> &'a [Override] {
        match self {
            CaseRef::Build(build) => &build.overrides,
            CaseRef::Spot(spot) => &spot.overrides,
        }
    }

    pub fn placement(&self) -> Option<&'a str> {
        match self {
            CaseRef::Build(build) => build.on.as_deref(),
            CaseRef::Spot(spot) => spot.on.as_deref(),
        }
    }
}

impl<S> Case<S> {
    pub fn as_ref(&self) -> CaseRef<'_, S> {
        match self {
            Case::Build(case) => CaseRef::Build(case),
            Case::Spot(case) => CaseRef::Spot(case),
        }
    }

    pub fn case_id(&self) -> &str {
        self.as_ref().case_id()
    }

    pub fn as_build(&self) -> Option<&Build<S>> {
        match self {
            Case::Build(case) => Some(case),
            Case::Spot(_) => None,
        }
    }
}

impl<S> Build<S> {
    pub fn case_id(&self) -> &str {
        self.case_id.as_deref().unwrap_or("case")
    }

    /// Requested sets, expanded: `all` covers everything, and packages or
    /// python imply the core toolchain they link against.
    pub fn requested_sets(&self) -> Vec<SetName> {
        let mut names: Vec<SetName> = Vec::new();
        let mut all = false;
        for selector in &self.selectors {
            if selector.kind != SelectorKind::Set {
                continue;
            }
            if selector.name == "all" {
                all = true;
            } else if let Some(set) = SetName::parse(&selector.name) {
                names.push(set);
            }
        }
        if all {
            return SetName::ORDER.to_vec();
        }
        if names
            .iter()
            .any(|set| matches!(set, SetName::Packages | SetName::Python))
            && !names.contains(&SetName::Core)
        {
            names.push(SetName::Core);
        }
        SetName::ORDER
            .into_iter()
            .filter(|set| names.contains(set))
            .collect()
    }

    pub fn requested_jobs(&self) -> Vec<String> {
        self.selectors
            .iter()
            .filter(|selector| selector.kind == SelectorKind::Job)
            .map(|selector| selector.name.clone())
            .collect()
    }
}

/// What prepare decided about the run, written once.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Preparation {
    /// Cases whose results were adopted from a published run, so the plan owes
    /// them no evaluation or builds.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub reused: Vec<String>,
}

impl Document for Preparation {
    const KIND: &'static str = "preparation";
    const SCHEMA: u32 = 1;
}
