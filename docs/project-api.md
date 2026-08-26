# Structured project API v1

Status: implemented. This document defines the public v1 contract.
Repository-specific additions under `internals` are not part of that contract.

Wasinix constructs one structured project for one evaluation system. A project
contains package sets, artifacts, commands, tests, and a CI catalog. Other
flakes use the same constructor and add packages through registered overlays.

## Constructor

```nix
wasinix.lib.mkProject {
  system = "x86_64-linux";
  importNixpkgs = args:
    import nixpkgs (
      args
      // {
        config = myNixpkgsConfig // (args.config or {});
        overlays = myNixpkgsOverlays ++ (args.overlays or []);
      }
    );
  extensions = [myExtension];
  ci.sources = ["my-project"];
  repository = {
    source = "my-project";
    root = self;
    revisionsFile = ./release-revisions.json;
    publication = {
      wasmer.registry = "wasmer.io";
      provenance = {
        flake = "github:owner/my-project";
        repository = "owner/my-project";
      };
    };
  };
}
```

`mkProject` returns the structured project, not complete flake outputs. A flake
may construct several projects and expose them under different attributes.

Bind the CLI and its command aliases to an exposed project with:

```nix
apps.${system} = wasinix.lib.appsForProject {
  inherit project;
  projectAttr = "legacyPackages.${system}";
};
```

The generated apps run the CLI from the pinned Wasinix input, derive optional
capabilities from `project`, and pass the exact project attr to every command. A
flake with several projects calls the helper once per project and chooses how to
name the resulting apps. `cliForProject` returns the corresponding full CLI
package when the flake also wants to expose it from `packages`.

`mkProject` is `mkEmptyProject` with the Wasinix extension and projection rules
prepended. Wasinix itself uses this composed constructor. `mkEmptyProject` is
the lower-level mechanism for projects that need the structured catalog without
the Wasinix package collection; it receives every extension and projection rule
explicitly.

The constructor takes:

- `system`: the local evaluation system.
- `importNixpkgs`: a caller-owned nixpkgs importer. Wasinix supplies
  `localSystem`, the applicable `crossSystem`, required configuration, and the
  overlays for the set being constructed. The importer may add nixpkgs
  configuration and ordinary overlays, but must preserve the supplied values.
- `extensions`: ordered registered overlay bundles added after the built-in
  Wasinix extension.
- `projectionRules`: additional named projection rules. Names must be disjoint
  from the built-in rules.
- `projectTests`: project-level test declarations containing `source`, a lazy
  `check = project: derivation` function, and optional CI policy. Package and
  artifact checks should remain projections; this input covers source-wide
  checks such as formatting.
- `repository`: optional ownership information for update and publication
  collection. Its `source` selects catalogued packages, `root` bounds update
  declarations to the repository, and `revisionsFile` supplies release state.
  `publication` declares registry destinations and provenance owned by that
  repository. The resulting revisions, source-filtered publication inventory,
  update scripts, notes, and hooks live under `internals.repository`.
- `ci.sources`: registered sources whose packages, artifacts, and tests become
  CI jobs. It defaults to the caller-supplied extension IDs, excluding the
  implicit core extension.
- `ci.groups`: additional named selector groups. A group declares its `jobs` as
  catalog addresses. Every consumer resolves those addresses through the same
  catalog.

A single pre-instantiated `pkgs` value is not sufficient. The constructor must
instantiate a native set and one cross set for each WASIX profile with the same
nixpkgs configuration and extension order.

The built-in extension has the ID `wasinix` and is implicit. Consumers do not
repeat it in `extensions`, but its ID remains visible in package provenance and
lineage.

The result starts with:

```nix
{
  schemaVersion = 1;
  packages = ...;
  commands = ...;
  artifacts = ...;
  runners = ...;
  probes = ...;
  ownership = ...;
  tests = ...;
  ci = ...;
}
```

The CLI evaluates `schemaVersion` before interpreting the rest of the project
and reports an unsupported-version error on mismatch. A serialized projection,
such as `ci.catalog`, repeats the value from this single project constant so it
can be consumed independently.

`probes.ifd` is a tiny text derivation used by `wasinix remote doctor --ifd` to
verify that a remote store can build a path which local evaluation then reads.

There is no compatibility layer for the current internal flake attributes. No
external stable API depends on them.

## Extensions and overlay order

An extension is an ownership and provenance boundary:

```nix
{
  id = "my-project";

  overlays = {
    packages = final: prev: {};
    python = final: prev: pyfinal: pyprev: {};
  };

  history = {
    wasix = ./pkgs/overlays/history.json;
    python = ./pkgs/python-overlays/history.json;
  };
}
```

`packages` is an ordinary nixpkgs overlay applied to the native set and every
WASIX profile set. `python` applies to each supported Python package fixpoint.
Absent lanes are empty, and extension list order is overlay order.

Ordinary overlays supplied by `importNixpkgs` are not registered. Their packages
may be used as dependencies, but they do not acquire Wasinix provenance or enter
the catalog merely because they exist in nixpkgs.

Every derivation returned by a registered overlay is cataloged by default.
Infrastructure derivations opt out where they are defined:

```nix
passthru.wasinix.catalog = false;
```

Returned non-derivations are not cataloged. The constructor still stamps source
ownership on a delisted derivation so later overrides can be validated.

### Overrides and lineage

The constructor stamps these fields; package authors do not set them:

```nix
passthru.wasinix.source = "my-project";
passthru.wasinix.lineage = ["wasinix" "my-project"];
```

An extension overriding a package owned by another registered extension must
declare the previous owner on the returned package:

```nix
passthru.wasinix.overrides = "wasinix";
```

The declaration is checked against the package immediately preceding the
overlay. A missing or mismatched declaration is an error. A declaration is also
an error when there is no preceding registered owner. Repeated layering inside
one extension needs no declaration; providing one there is an error.

Lineage is derived from the validated overlay chain. It is never handwritten.

### Ownership

An extension may register maintainers and logical review teams. These are
project-policy identities, not nixpkgs `meta.maintainers`, and a team does not
need a corresponding GitHub team:

```nix
{
  id = "my-project";

  ownership = let
    maintainers.janeDoe.github = "jane-doe";
  in {
    inherit maintainers;
    teams.php = [maintainers.janeDoe];
  };
}
```

Each maintainer is exactly `{ github = <nonempty login>; }`; each team is a list
of values from that extension's maintainer registry. Package units receive their
owning extension's `maintainers` and `teams` arguments, so package policy
references the typed central values instead of repeating GitHub logins. The
project exposes the contributions as `ownership.<extension-id>`.

The repository's `core` team is the default assignee and reviewer set for all
updates, including flake inputs. It may be empty while the project establishes
its roster; package declarations can still name a narrower typed owner set.

## File layout and discovery

Extensions may handwrite every overlay. Wasinix also provides a convenience
loader for repositories that keep one package unit per file:

```nix
{
  id = "my-project";

  overlays = wasinix.lib.loadPackageOverlays {
    packages = {
      directory = ./pkgs/overlays;
      lane = "packages";
      inherited = {
        libfoo = {};
        libbar.supportedProfiles = ["eh" "ehpic"];
      };
    };
    python = {
      directory = ./pkgs/python-overlays;
      lane = "python";
    };
  };

  history = {
    wasix = ./pkgs/overlays/history.json;
    python = ./pkgs/python-overlays/history.json;
  };
}
```

The Wasinix extension uses the same helper. Its package area follows this shape:

```text
pkgs/
├── project/
│   └── extension.nix
├── overlays/
│   └── history.json
├── python-overlays/
│   └── history.json
├── python/
│   ├── lib/
│   └── wheels/
├── set/
├── checks/
├── artifacts/
├── harnesses/
├── runners/
└── toolchain/
```

Both inventories use one-character buckets derived from the first character of
the package attribute, for example `overlays/z/zlib.nix` and
`python-overlays/s/scipy/package.nix`. A wrong bucket, loose support file, or
duplicate flat and directory entry is an error.

The regular package inventory accepts three forms:

- `<bucket>/<name>.nix`: a WASIX-only adaptation with no support files;
- `<bucket>/<name>/wasix.nix`: the same, with colocated patches or tests;
- `<bucket>/<name>/package.nix`: a complete package definition, with native and
  WASIX behavior in one file.

The package declaration's `inherited` attribute set registers preceding nixpkgs
packages which require no WASIX adaptation. Each value is merged into the
package's `passthru.wasix`. An inherited name cannot also have an inventory
unit, and every inherited name must exist in the preceding package set.

`wasix.nix` is instantiated only when the actual package-set host platform is
WASIX, including across nixpkgs' build-package splices. `package.nix` is
instantiated in native and WASIX sets and may branch on its `scope` argument. A
complete unit requesting `exposeNativePackage` is instantiated in the native
set, receives `supportedProfiles = []`, and is reused as host-side plumbing in
WASIX sets. An entry cannot contain both files. `recipe.nix` is obsolete and
rejected.

`supportedProfiles = []` controls catalog support, not overlay instantiation.
Use `exposeNativePackage` when the package itself must only be constructed in
the native set.

The Python inventory accepts `<bucket>/<name>.nix` or
`<bucket>/<name>/package.nix`. Package-specific patches and tests belong inside
the directory entry that owns them. Shared Python construction helpers and the
wheel declarations remain under `pkgs/python/lib/` and `pkgs/python/wheels/`.

The loader performs only these jobs:

- discover package units;
- register declared inherited packages;
- turn them into an overlay for their lane;
- preserve source positions for diagnostics;
- reject duplicate attributes between discovered units;
- validate each unit's result.

It does not construct history, attach tests, derive support policy, discover
extensions, or maintain a parallel package-name list.

### Package units

Every package unit returns an attrset of derivations. A complete package uses
`exposePackage` to bind one derivation to the discovered name:

```nix
# overlays/m/my-tool/package.nix
{
  exposePackage,
  packageSet,
}:
exposePackage (packageSet.callPackage ./build.nix {})
```

Wasinix ties one lazy recursive context containing the final project projections
and construction helpers, then passes its members by name, like `callPackage`.
Every constructor receives that same context and requests only the fields it
uses. The context includes:

- `packages.sameProfile`: the immediate recursive package set.
- `packages.wasix.preferred`: the attribute-wise projection of each package's
  preferred WASIX profile.
- `packageSet`: the immediate undecorated nixpkgs or Python fixpoint.
- `scope` and `variant`: the actual package-set scope and its profile or
  interpreter key.
- `commands`, `artifacts`, `harnesses`, `runners`, and `probes`.
- `extendPackage` and the other focused package helpers.

A package-unit invocation additionally supplies `package`, the preceding value
of the attribute being defined, when one exists. `exposePackage derivation`
returns the lazy singleton result, while `exposeExtendedPackage attrs` combines
that operation with `extendPackage package attrs`. A unit that defines a new
attribute does not request `package` or `exposeExtendedPackage`; doing so is an
error. Raw extension overlays retain the standard `final: prev:` interface; the
discovered unit API does not duplicate those names.

A WASIX adaptation uses the corresponding cross-only helper:

```nix
# overlays/z/zlib.nix
{
  exposeWasixExtendedPackage,
  packages,
}:
exposeWasixExtendedPackage {
  buildInputs = [packages.sameProfile.someDependency];
}
```

`exposeWasixPackage`, `exposeWasixExtendedPackage`, and
`exposeWasixExtendedPackages` require preceding nixpkgs attributes. They are
never invoked in native package sets because `wasix.nix` units are absent there.

The singleton helpers preserve the overlay fixpoint: the loader can discover the
result attribute without forcing the derivation, so that derivation may depend
on `packages.sameProfile`. Returning a bare derivation is an error. When
`exposePackage` gives a derivation a new registered identity, it drops machine
provenance inherited from another package before the loader stamps the new
identity. Extending an existing registered attribute preserves its lineage.

There is no staged context that withholds later projections from package
construction. Nix evaluates fields lazily, so a unit may reference any final
projection. If forcing that reference creates a dependency cycle, evaluation
fails with the ordinary Nix cycle error.

`extendPackage package attrs` is the common additive override. It concatenates
phase scripts, appends lists, recursively merges non-derivation attrsets, lets a
function transform the old value, and replaces other values. The name describes
that merge contract; it does not stand for a general helper collection.

`extendPackage` does not set `doCheck` or otherwise decide test policy.
Capturing and executing a package's build suite belongs to the check machinery.
It also has no Python-specific behavior. Python package construction recomputes
`requiredPythonModules` from the final propagated inputs after registered
overlays have been applied.

An override that does not want additive merging uses `package.overrideAttrs`
directly. Narrow helpers such as script concatenation and input filtering remain
available directly as `mergeScript`, `dropInputsByName`,
`dropInputsByNameInfix`, `replaceInputsByName`, `linkInputs`,
`dropPatchesByNameInfix`, and `dropFlagsByPrefix`. There is no `libTweaks` or
generic `helpers` compatibility name in the v1 package-unit API. Profile-aware
units request `profileOf`, `profileTraitsOf`, or the named `profileSets` subsets
directly, `buildHostPypaTools` and `dropSphinxDocs` cover common Python build
adaptations, and `wasmRename` normalizes command filenames before WebC
projection.

A unit that genuinely owns several preceding WASIX attributes uses:

```nix
{exposeWasixExtendedPackages}:
exposeWasixExtendedPackages {
  llvm = {};
  clang = previous: previous.overrideAttrs (_: {doCheck = true;});
}
```

An attrset value uses `extendPackage`; a function receives the corresponding
preceding package and returns its replacement. A complete unit constructing
several new packages returns the attrset directly. All returned values must be
derivations, and the returned attribute shape must be the same in every variant
where the unit is instantiated. Unrelated packages use separate units; a
multi-package unit is for construction that is actually shared.

Python units use the same `packages.sameProfile` name for their immediate Python
fixpoint:

```nix
{
  package,
  packages,
  pkgs,
  extendPackage,
}:
extendPackage package {
  propagatedBuildInputs = [
    packages.sameProfile.somePythonDependency
    pkgs.openblas
  ];
}
```

For Python, `pkgs` is the enclosing WASIX package set and `packageSet` is the
immediate Python fixpoint.

Auto-discovered units must return disjoint attributes. Same-extension layering
uses explicitly composed overlays so its order is visible rather than derived
from filename ordering.

## Profiles, packages, and toolchains

`pkgs/project/profiles.nix` remains the canonical WASIX profile inventory.
`mkProject` constructs every profile. Packages declare their supported profiles
and an optional preferred profile; the project constructor does not carry a
second profile selection mechanism.

LLVM, Rust, wasixcc, sysroots, cargo-registry, anybuild, and similar buildable
values are packages and may be used directly in development shells. Their
profile-specific construction interfaces are projections on the native package
that owns them rather than a separate toolchain category.

The structured views are:

```nix
{
  packages = {
    native = ...;
    wasix = {
      <profile> = ...;
      preferred = ...;
    };
    python.<interpreter> = ...;
  };

  packages.native.wasixcc.profiles.<profile>.stdenv = ...;
  packages.native.wasix-rust.profiles.<profile>.rustPlatform = ...;
  packages.native.wasix-sysroot.profiles.<profile>.sysroot = ...;
}
```

There is no `packages.toolchain` or top-level `toolchain` namespace. Buildable
toolchain artifacts are ordinary native packages. Profile-specific construction
interfaces are lazy package projections, like retained versions. There is also
no architectural product category: a complete package is supplied through the
regular package overlay, and shipping is an independent package policy.

The standard `packages.<system>` flake output remains small, normally exposing
only `wasinix` and a default. The complete structured project belongs under
`legacyPackages.<system>` or another flake-specific output chosen by the
consumer. Toolchain and catalog packages do not need duplicate top-level flake
attributes.

The CLI accepts `--project FLAKE#PROJECT-ATTR`; it defaults to
`.#legacyPackages.x86_64-linux`. This reference selects the structured project,
independently of the pinned Wasinix flake supplying the CLI and optional tools.

`packages.wasix.preferred` is generally available but is not a coherent nixpkgs
package set: two attributes may select different profiles. Linked dependencies
use the immediate `packages.sameProfile` context. Runtime commands, non-linked
tools, and default artifacts may deliberately use `packages.wasix.preferred`.

## Package metadata

Authored metadata is divided by its consumer:

```nix
passthru = {
  wasix = {
    supportedProfiles = [...];
    preferredProfile = "...";
    broken = "...";
  };

  wasmer = {
    commands = [...];
    entrypoint = "...";
    dependencies = [...];
    fs = {...};
    env = {...};
  };

  wasinix = {
    catalog = false;
    overrides = "...";
    shipped = true;
    aliases = [...];
    ci = {
      profiles = [...];
      tags = [...];
    };
    checks = {...};
    retention = "...";
    update = {...};
  };
};
```

`passthru.wasix` describes WASIX compatibility. `passthru.wasmer` describes a
Wasmer manifest and runtime package. `passthru.wasinix` describes catalog,
testing, CI, release, and update policy.

`source`, `lineage`, and `instance` are reserved machine-stamped members of
`passthru.wasinix`. `aliases`, `shipped`, CI profiles and tags, checks,
retention, and update policy do not belong to the WASIX ABI or Wasmer manifest
namespaces.

## Catalog

The constructor creates one canonical internal catalog. Package views,
artifacts, commands, tests, and CI are projections from it rather than
independently maintained inventories.

A package entry has this shape:

```nix
{
  kind = "package";
  address = "packages.wasix.exnrefEh.jq";
  source = "wasinix";
  lineage = ["wasinix"];
  scope = "wasix";
  variant = {profile = "exnrefEh";};
  instance = {
    kind = "current";
    version = "1.7.1";
  };
  package = jqDerivation;
  policy = normalizedWasinixPassthru;
}
```

`project.catalog.entries.<address>` contains full Nix records, including
derivations, helper values, and the entry-relative `artifacts`, `commands`, and
`tests` projections. `ci.catalog` is its serializable CI projection; it is not a
second catalog. Its source-filtered `jobs` are evaluable CI work, while
`packages` retains the current package domain needed to resolve selectors in
downstream projects.

Addresses are canonical structured-project paths. Examples include:

```text
packages.wasix.exnrefEh.zlib
packages.python.py314.numpy
packages.python.preferred.numpy
packages.native.wasix-llvm
tests.packages.wasix.exnrefEh.zlib.abi
artifacts.webc.git
commands.git
```

The implementation owns one encoder and parser for addresses, including
attribute names and versions that require escaping. Filesystem paths and display
labels never act as package identity.

## History, revisions, and releases

Terminology is fixed as follows:

- `history`: retained older upstream versions.
- `revision`: Wasinix's rebuild number for one upstream version.
- `release`: a fully resolved distributable identity.
- `publish`: the external operation that changes registry state.

Revision state lives in `release-revisions.json`.

History supports WASIX and Python packages adapted from their immediate
preceding package. History for complete package definitions is not required for
v1.

The built-in history projection applies to current package entries and returns
retained derivations in its `versions` namespace. To instantiate one, the rule:

1. replaces the unit's `package` argument with the upstream package rebased to
   the retained source pin;
2. stamps the requested instance;
3. replays the owning package unit or overlay;
4. validates the resulting version;
5. returns the result as a package projection.

The projection engine recursively projects those results. History therefore uses
the same rule registration and entry context as a consumer-supplied package
projection; the engine has no separate historical test path.

The instance visible during replay is:

```nix
passthru.wasinix.instance = {
  kind = "history";
  version = "1.6";
};
```

Current instances use `kind = "current"`. Historical packages use current
dependencies by default. A package that requires an older dependency addresses
that dependency explicitly through the structured history views.

History is the `versions` projection of a package view, not a separate package
axis. Public absolute views expose it without minting synthetic top-level
nixpkgs attributes:

```nix
packages.wasix.<profile>.jq.versions."1.6"
packages.python.py314.numpy.versions."2.1.3"
packages.wasix.<profile>.jq
packages.python.py314.numpy
packages.python.preferred.numpy
```

One Python interpreter spec may set `preferred = true`. Its package set is
available as `packages.python.preferred`, independently of the interpreter's
versioned key.

Construction and test code use contextual views when the profile is relative to
the entry being constructed or checked:

```nix
packages.sameProfile.openssl
packages.sameProfile.openssl.versions."1.1.1w"
packages.wasix.preferred.bash
packages.wasix.preferred.bash.versions."5.2"
```

A release records the artifact identity rather than modifying the source package
derivation:

```nix
{
  name = "numpy";
  version = "2.3.1";
  revision = 2;
  format = "wheel";
}
```

Current and historical package instances pass through the same projection
machinery. History is not a special artifact or test class.

## Artifacts and commands

The general construction operation maps a catalog entry to typed projections:

```nix
projectionRules.wasmerArtifacts = {
  namespaces = ["artifacts"];
  entry = {
    entry,
    artifacts,
    ...
  }:
    lib.optionalAttrs (entry.policy.shipped or false) {
      artifacts = {
        pkg = pkgDerivation;
        webc = webcDerivation;
      };
    };
};

projectionRules.historyVersions = {
  namespaces = ["versions"];
  entry = {entry, instantiateVersions, ...}: {
    versions = instantiateVersions entry;
  };
};

projectionRules.wasmerCommands = {entry, ...}:
  lib.optionalAttrs (entry.kind == "artifact" && entry.artifactKind == "webc") {
    commands.git = {
      name = "git";
      artifact = entry.artifact;
      entrypoint = "git";
    };
  };

projectionRules.packagedBehavior = {entry, harnesses, ...}:
  lib.optionalAttrs (entry.kind == "artifact" && entry.artifactKind == "webc") {
    tests.packaged = packagedBehaviorCheck;
};

projectionRules.pythonRegistry = {
  source = "my-project";
  namespaces = ["artifacts"];
  project = {catalog, packages, ...}: {
    artifacts.registry.python = {
      artifact = registryDerivation;
      subjects = wheelEntryAddresses;
    };
  };
};
```

Every rule declares the typed namespaces it can produce and returns a possibly
empty attrset containing those namespaces. `entry` runs once for every catalog
entry and produces paths relative to that entry. A bare function is shorthand
for this callback with the `artifacts`, `commands`, and `tests` namespaces.
`project` runs once over the complete lazy project and produces absolute paths;
v1 permits project-level `artifacts`. A structured rule may provide either or
both callbacks.

`versions` contains package projections; `artifacts`, `commands`, and `tests`
contain their corresponding entry kinds. Results merge disjointly within each
namespace; collisions, undeclared outputs, invalid payloads, and unregistered
project-artifact sources are errors.

Artifacts are distributable derivation projections. WebCs, wheels, registries,
and similar outputs live under their subject entry and in a global view indexed
by artifact kind and subject identity, such as `artifacts.webc.git`. Their
catalog entries inherit the subject's provenance and instance identity. Artifact
entries may themselves pass through projection rules, allowing packaged behavior
tests to belong to the WebC rather than its source package. Commands and tests
are terminal entry kinds in v1.

Project artifacts are ordinary catalog entries too. Their declaration names a
registered `source` on the rule and may name immediate catalog dependencies in
`subjects`. The constructor validates those addresses and derives the transitive
package ownership as `packageSubjects`. Entry projections then run on the
project artifact exactly as they do on package-produced artifacts. This is how
an aggregate such as the Python registry receives its own behavior tests and is
included in CI whenever any selected package contributes to it.

Commands describe packaged commands as facts:

```nix
commands.git = {
  name = "git";
  artifact = artifacts.webc.git;
  entrypoint = "git";
};
```

A retained artifact exposes its commands through its own `commands` projection.
The global view retains the current command at `commands.git` and older command
instances at `commands.git.versions.<version>`.

A command record does not store several executable wrappers. Test harnesses
project it according to the execution environment:

- a host-shell harness creates a host-visible Wasmer wrapper;
- a WASIX-shell harness adds the WebC as a guest dependency;

Specialized harnesses may use the internal packaged-command executor when they
need to invoke one artifact entrypoint without constructing a shell workflow.

Raw build-tree Wasm execution is separate from packaged WebC execution. Both
late-bind the Wasmer runtime so a runtime update reruns checks without
rebuilding the package under test, but they have different inputs, mounts, and
entrypoint semantics. The runner API distinguishes an unbound raw-Wasm launcher
from one paired with a runtime; it does not call the former a stub.

```nix
runners.rawWasm.unbound
runners.rawWasm.withRuntime
```

There is no separate `runtime` namespace duplicating Wasmer, WASIX commands, or
packaged Python. Commands, artifacts, harnesses, and runners expose those roles
where they are consumed.

## Tests

Both projection callbacks destructure the same lazy recursive project context:

```nix
{
  packages,
  packageSets,
  pythonVariants,
  catalog,
  commands,
  artifacts,
  tests,
  harnesses,
  pkgs,
}
```

An `entry` callback additionally receives `entry`, exactly the canonical
internal catalog entry being projected, and entry-relative conveniences such as
`packages.sameProfile`. It is not a second context record with copied package
fields. The fields below are common projection dependencies, not a test-owned
API:

- `packages.native`, `packages.wasix.<profile>`, `packages.wasix.preferred`, and
  `packages.python`, with retained history under each package's `versions`;
- `packages.sameProfile` for entry callbacks, where the entry supplies a package
  scope and variant;
- `packageSets`, the undecorated native, WASIX profile and preferred, and Python
  package sets;
- `pythonVariants`, including the configured variants, their interpreter
  packages, and the preferred variant;
- `catalog` and `tests`;
- `commands`;
- entry-relative and global `artifacts` views;
- `harnesses`;
- `probes`;
- `pkgs`, the scope-appropriate construction set for entry callbacks and the
  native package set for project callbacks.

The package-unit argument `package` remains distinct: it is the preceding
derivation being adapted. A projection rule's `entry` is the completed canonical
record, which may represent a package or artifact. These are the only
constructor-specific fields; every other requested argument is a projection of
the same shared context.

An empty attrset means a rule does not apply. A rule may return several named
test shards alongside artifacts and commands. There is no separate `appliesTo`
operation and no architectural distinction between current-package and
history-package checks.

Tests are projections, not instances of a fixed upstream, ABI, link, or behavior
taxonomy. The captured-suite projection applies when a package provides the
prepared check output. Link checks require explicit package policy, such as
`passthru.wasinix.checks.link`; the machinery does not infer a `packageKind`.
Per-package ABI projections reject contradictory evidence from that package.
Separate profile witnesses establish positive profile capabilities, such as
support for PIC relocations, because no individual package necessarily exercises
every capability.

Package-specific behavior checks live in `tests/*.nix` beside a directory-form
package unit. Each file receives the same projection arguments and returns a
possibly empty attrset of named test derivations. A sibling `tests/helpers.nix`
may return shared values, available to test files as `helpers`; duplicate names
and non-derivation results are errors. The packaged-behavior rule discovers this
directory from the preserved package definition, so current and historical WebC
artifacts use the same files. Cross-cutting rules and profile witnesses live
under the extension's central `checks/` area. Generated tests belong to the
project test catalog; they are not attached back to packages as an authoritative
`passthru.tests` tree.

All applicable checks are constructed for current and historical instances. The
history projection stamps its package results with a gated tag such as
`history-tests`, which ordinary policy inheritance carries to their artifacts
and tests. Normal CI does not execute them, and a direct selection still
requires enabling the tag. Other expensive properties add their own tags rather
than replacing the history tag.

Checks use the highest meaningful end-to-end layer:

- ABI and captured build-suite checks use package outputs where required.
- Command behavior runs the actual WebC.
- Python behavior installs the actual wheel into a clean target and runs it
  through the packaged Python WebC.
- Registry behavior consumes the generated registry.

Captured upstream suites store their test tree in a package output and run it
later with an unbound raw-Wasm launcher. The final check supplies Wasmer. A
runtime change therefore reruns the suite without rebuilding the package.

### Shell harnesses

The host shell harness runs native Bash and makes explicitly selected WASIX
commands available as generated host wrappers:

```nix
harnesses.hostShell {
  hostPackages = [pkgs.curl];
  wasixCommands = [commands.git];
  script = ''
    git --version
  '';
}
```

The WASIX shell harness runs its main script inside a packaged WASIX Bash and
adds selected commands as WebC dependencies:

```nix
harnesses.wasixShell {
  shell = commands.bash;
  commands = [commands.cat commands.curl commands.sleep];

  host = {
    packages = [pkgs.minio];
    setup = ''
      minio server "$TMPDIR/data" &
      server_pid=$!
      export TEST_ENDPOINT=http://127.0.0.1:9000
    '';
    teardown = ''
      kill "$server_pid"
    '';
  };

  forwardEnv = ["TEST_ENDPOINT"];
  capabilities.network = true;
  mounts = [{source = ./fixtures; target = "/fixtures";}];

  script = ''
    curl "$TEST_ENDPOINT/health"
  '';
}
```

The harness installs cleanup handling before setup, runs teardown after success,
failure, or interruption, and keeps setup and teardown in the same host shell.
Forwarded values are captured after setup. A mount names a path or derivation
and a unique absolute non-root guest target. `network` is the v1 capability;
unknown host fields, capabilities, mount fields, and duplicate command or mount
names are errors. Only named environment variables, capabilities, and mounts
cross into the guest.

Host shell remains appropriate for native fixtures, host comparisons, and
runtime coordination. WASIX shell is preferred when the behavior under test is a
workflow intended to run entirely inside WASIX.

The Python harness runs a wheel through the packaged Python WebC in a clean
pip-like target without mounting the Nix store:

```nix
harnesses.python {
  name = "wheel-pytest-foo";
  inherit wheel;
  deps = [pythonPkgs.pytest];
  script = ''
    import pytest
    raise SystemExit(pytest.main(["-q"]))
  '';
}
```

## CI

Nix publishes derivations and selection facts. The Wasinix CLI owns selection
semantics, including aliases, globs, named selector expansion, omitted variants,
tag gates, union, deduplication, and errors.

The public CI value is:

```nix
ci = {
  jobs = {
    "<canonical-job-id>" = derivation;
  };

  catalog = {
    schemaVersion = project.schemaVersion;
    jobs = {
      "<canonical-job-id>" = serializableMetadata;
    };
    selectors = {...};
  };
};
```

`ci.jobs` contains derivations only. `ci.catalog` contains no derivations. Their
job key sets must be exactly equal, which the constructor enforces.

`ci.catalog.selectors.sources.<extension-id>` records the jobs in each selected
source's package closure. This is factual membership for the CLI's
`source=<extension-id>` filter, not a second selector implementation in Nix.

The project decides which registered sources contribute CI jobs. By default, all
caller-supplied extensions contribute and the implicit core extension does not.
The Wasinix repository selects its own `wasinix` source explicitly. Dependencies
from other sources remain available in package sets without automatically
becoming CI jobs.

`all` expands to exactly every key in `ci.jobs`. The CLI then applies tag gates;
a normal invocation does not admit jobs tagged `history-tests`, and a direct
request for one reports the tag that must be enabled. Gated jobs remain present
in the jobs map and catalog. The CLI parses a user's selectors, resolves them
against `ci.catalog`, then requests the exact selected job IDs from Nix in one
batched evaluation. Any Nix helper for that lookup is an implementation detail,
not a public selector engine.

The current parallel `ci`, `ciSets`, `ciGroups`, `ciJobInfo`, and
`ciSelectorCatalog` inventories collapse into this one jobs map and its catalog
projection.

## Required validation

The implementation must enforce the structural rules in the same change that
introduces them:

- extension IDs are unique and the built-in `wasinix` ID cannot be replaced;
- package-unit attributes are disjoint and invariant across applicable variants;
- registered overrides match their declared previous owner;
- machine-stamped provenance cannot be authored or overwritten;
- package, artifact, command, test, and job addresses are unique;
- generated projection outputs merge disjointly within each typed namespace;
- aliases resolve to one canonical entry and cannot shadow another address;
- `ci.jobs` and `ci.catalog.jobs` have identical keys;
- every serialized catalog carries the project schema version.

The directory loader derives package-unit names from their sharded paths and
values from their returned attrsets. Its eval-only tests must cover complete and
WASIX-only units, inherited packages, a singleton adaptation depending on the
immediate recursive set, a multi-package unit, rejection of a bare derivation,
wrong buckets, conflicting entry forms, obsolete `recipe.nix`, and loose support
files.
