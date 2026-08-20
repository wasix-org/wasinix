# Structured project API v1

Status: agreed design, not yet implemented. The current implementation is
described in [`architecture.md`](architecture.md). This document is the contract
for replacing it; until that work lands, its attribute paths are not available
from the flake.

Wasinix constructs one structured project for one evaluation system. A project
contains package sets, toolchain integration, artifacts, commands, tests, and a
CI catalog. Other flakes use the same constructor and add packages through
registered overlays.

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
}
```

`mkProject` returns the structured project, not complete flake outputs. A flake
may construct several projects and expose them under different attributes.

The constructor takes:

- `system`: the local evaluation system.
- `importNixpkgs`: a caller-owned nixpkgs importer. Wasinix supplies
  `localSystem`, the applicable `crossSystem`, required configuration, and the
  overlays for the set being constructed. The importer may add nixpkgs
  configuration and ordinary overlays, but must preserve the supplied values.
- `extensions`: ordered registered overlay bundles added after the built-in
  Wasinix extension.
- `ci.sources`: registered sources whose packages, artifacts, and tests become
  CI jobs. It defaults to the caller-supplied extension IDs, excluding the
  implicit core extension.

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
  toolchain = ...;
  commands = ...;
  artifacts = ...;
  tests = ...;
  ci = ...;
}
```

The CLI evaluates `schemaVersion` before interpreting the rest of the project
and reports an unsupported-version error on mismatch. A serialized projection,
such as `ci.catalog`, repeats the value from this single project constant so it
can be consumed independently.

There is no compatibility layer for the current internal flake attributes. No
external stable API depends on them.

## Extensions and overlay order

An extension is an ownership and provenance boundary:

```nix
{
  id = "my-project";

  overlays = {
    shared = final: prev: {};
    native = final: prev: {};
    wasix = final: prev: {};
    python = final: prev: pyfinal: pyprev: {};
  };

  history = {
    wasix = ./wasix/history.json;
    python = ./python/history.json;
  };
}
```

Overlay lanes have application semantics rather than package roles:

- `shared` applies to the native set and every WASIX profile set.
- `native` applies only to the native set.
- `wasix` applies to every WASIX profile set.
- `python` applies to each supported Python package fixpoint.

Absent lanes are empty. Extension list order is overlay order. Within an
extension, `shared` precedes the set-specific lane.

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

## File layout and discovery

Extensions may handwrite every overlay. Wasinix also provides a convenience
loader for repositories that keep one package unit per file:

```nix
{
  id = "my-project";

  overlays = wasinix.lib.loadPackageOverlays {
    shared = ./shared;
    native = ./native;
    wasix = ./wasix;
    python = ./python;
  };

  history = {
    wasix = ./wasix/history.json;
    python = ./python/history.json;
  };
}
```

The Wasinix extension uses the same helper. Its package area follows this shape:

```text
pkgs/
├── extension.nix
├── shared/
├── native/
├── wasix/
│   └── history.json
├── python/
│   └── history.json
├── checks/
├── artifacts/
└── toolchain/
```

The package lanes describe where an overlay applies. Catalog roles such as
toolchain or shipped do not determine file placement. Toolchain profile
integration remains under `toolchain/`; buildable compiler and sysroot packages
live in the package lane matching where they are instantiated.

Discovery is shallow. A lane contains either `<name>.nix` or
`<name>/package.nix`. Other files and directories are ignored. A directory form
co-locates patches, package-specific checks, and other inputs with the unit that
uses them.

The loader performs only these jobs:

- discover package units;
- turn them into an overlay for their lane;
- preserve source positions for diagnostics;
- reject duplicate attributes between discovered units;
- validate each unit's result.

It does not construct history, attach tests, derive support policy, discover
extensions, or maintain a parallel package-name list.

### Package units

A single-package unit returns a derivation. Its file or directory name supplies
the overlay attribute:

```nix
# wasix/zlib.nix
{
  package,
  packages,
  extendPackage,
}:
extendPackage package {
  buildInputs = [packages.sameProfile.someDependency];
}
```

Wasinix ties one lazy recursive context containing the final project projections
and construction helpers, then passes its members by name, like `callPackage`.
Every constructor receives that same context and requests only the fields it
uses. The context includes:

- `packages.sameProfile`: the immediate recursive package set.
- `packages.preferred`: the attribute-wise projection of each package's
  preferred WASIX profile.
- `commands`, `artifacts`, and `harnesses`.
- `extendPackage` and the other focused package helpers.

A package-unit invocation additionally supplies `package`, the preceding value
of the attribute being defined. A unit that defines a new attribute does not
request it; requesting it when no preceding attribute exists is an error. Raw
extension overlays retain the standard `final: prev:` interface; the discovered
unit API does not duplicate those names.

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
available for explicit overrides; there is no `libTweaks` compatibility name in
the v1 API.

A new package can retain a normal nixpkgs recipe:

```nix
# shared/my-tool/package.nix
{packages}:
packages.sameProfile.callPackage ./recipe.nix {}
```

A unit that genuinely owns several attributes returns an attrset of derivations:

```nix
{packages}: {
  llvm = packages.sameProfile.callPackage ./llvm.nix {};
  clang = packages.sameProfile.callPackage ./clang.nix {};
}
```

This replaces a separate `{names, packages}` declaration. All returned values
must be derivations, and the returned attribute shape must be the same in every
variant where the unit is instantiated. Unrelated packages use separate units; a
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

For Python, `pkgs` is the enclosing WASIX package set. This is the only
additional scope Python needs.

Auto-discovered units must return disjoint attributes. Same-extension layering
uses explicitly composed overlays so its order is visible rather than derived
from filename ordering.

## Profiles, packages, and toolchains

`pkgs/profiles.nix` remains the canonical WASIX profile inventory. `mkProject`
constructs every profile. Packages declare their supported profiles and an
optional preferred profile; the project constructor does not carry a second
profile selection mechanism.

Toolchain is a package role, not a separate kind of build result. LLVM, Rust,
wasixcc, sysroots, cargo-registry, anybuild, and similar buildable values are
packages and may be used directly in development shells. Toolchain profile
integration is separate because an stdenv or language platform is package-set
plumbing rather than a distributable compiler artifact.

The structured views are:

```nix
{
  packages = {
    toolchain = ...;
    native = ...;
    wasix.<profile> = ...;
    python.<interpreter> = ...;
    preferred = ...;
  };

  toolchain.profiles.<profile>.integration = {
    stdenv = ...;
    rustPlatform = ...;
    # Other profile-specific builders.
  };
}
```

There is no `toolchain.artifacts` namespace. Buildable toolchain artifacts are
already packages. There is also no architectural product category: a shared
recipe is a package supplied through the `shared` overlay lane, and shipping is
an independent package policy.

The standard `packages.<system>` flake output remains small, normally exposing
only `wasinix` and a default. The complete structured project belongs under
`legacyPackages.<system>` or another flake-specific output chosen by the
consumer. Toolchain and catalog packages do not need duplicate top-level flake
attributes.

`packages.preferred` is generally available but is not a coherent nixpkgs
package set: two attributes may select different profiles. Linked dependencies
use the immediate `packages.sameProfile` context. Runtime commands, non-linked
tools, and default artifacts may deliberately use `packages.preferred`.

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

The constructor creates one canonical internal catalog. Package views, tests,
artifacts, and CI are projections from it rather than independently maintained
inventories.

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
derivations and helper values. `ci.catalog` is its serializable CI projection;
it is not a second catalog.

Addresses are canonical structured-project paths. Examples include:

```text
packages.wasix.exnrefEh.zlib
packages.python.py314.numpy
packages.toolchain.llvm
tests.packages.wasix.exnrefEh.zlib.abi
artifacts.webc.git
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

History initially supports packages adapted from `prev` and Python packages
adapted from their immediate `prev`. Shared-recipe history is useful but is not
required for v1.

To instantiate a historical package, the constructor:

1. replaces the unit's `package` argument with the upstream package rebased to
   the retained source pin;
2. stamps the requested instance;
3. replays the owning package unit or overlay;
4. validates the resulting version;
5. catalogs the result like any other package.

The instance visible during replay is:

```nix
passthru.wasinix.instance = {
  kind = "history";
  version = "1.6";
};
```

Current instances use `kind = "current"`. Historical packages use current
dependencies by default. A recipe that requires an older dependency addresses
that dependency explicitly through the structured history views.

History is the `versions` projection of a package view, not a separate package
axis. Public absolute views expose it without minting synthetic top-level
nixpkgs attributes:

```nix
packages.wasix.<profile>.jq.versions."1.6"
packages.python.py314.numpy.versions."2.1.3"
packages.wasix.<profile>.jq
packages.python.py314.numpy
```

Construction and test code use contextual views when the profile is relative to
the entry being constructed or checked:

```nix
packages.sameProfile.openssl
packages.sameProfile.openssl.versions."1.1.1w"
packages.preferred.bash
packages.preferred.bash.versions."5.2"
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

Current and historical package instances pass through the same artifact and test
machinery. History is not a special test class.

## Artifacts and commands

Artifacts are distributable projections of package entries. WebCs, wheels,
registries, and similar outputs live under `artifacts` and retain the package
entry's provenance and instance identity.

Commands describe packaged commands as facts:

```nix
commands.git = {
  name = "git";
  artifact = artifacts.webc.git;
  entrypoint = "git";
};
```

A command record does not store several executable wrappers. Test harnesses
project it according to the execution environment:

- a host-shell harness creates a host-visible Wasmer wrapper;
- a WASIX-shell harness adds the WebC as a guest dependency;
- a direct-command harness executes the artifact entrypoint.

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

Every test constructor destructures the same lazy recursive context:

```nix
{
  entry,
  packages,
  commands,
  artifacts,
  harnesses,
}
```

`entry` is exactly the canonical internal catalog entry being checked. It is not
a second context record with copied package fields. The fields below are common
check dependencies, not a test-owned or test-only API:

- `packages.sameProfile` and `packages.preferred`, with retained history under
  each package's `versions`;
- `commands`;
- entry-relative and global `artifacts` views;
- `harnesses`.

The package-unit argument `package` remains distinct: it is the preceding
derivation being adapted. A test's `entry` is the completed canonical record,
which may represent a package, artifact, or another catalog entry kind. These
are the only constructor-specific fields; every other requested argument is a
projection of the same shared context.

A generated check rule is one function that returns a possibly empty attrset:

```nix
checkRules.abi = {entry}:
  lib.optionalAttrs (supportsAbiCheck entry) {
    abi = checkDerivation;
  };
```

An empty attrset means the rule does not apply. A rule may return several named
shards. Rule outputs are merged disjointly, and collisions are errors. There is
no separate `appliesTo` operation and no architectural distinction between
current-package and history-package checks.

Checks are constructors and rules, not a taxonomy of upstream, ABI, link, or
behavior test classes. The captured-suite rule applies when a package provides
the prepared check output. Link checks require explicit package policy, such as
`passthru.wasinix.checks.link`; the machinery does not infer a `packageKind`.
Per-package ABI rules reject contradictory evidence from that package. Separate
profile witnesses establish positive profile capabilities, such as support for
PIC relocations, because no individual package necessarily exercises every
capability.

Package-specific behavior checks are colocated with the package unit and named
through `passthru.wasinix.checks`. Cross-cutting rules and profile witnesses
live under the extension's central `checks/` area. Generated tests belong to the
project test catalog; they are not attached back to packages as an authoritative
`passthru.tests` tree.

All applicable checks are constructed for current and historical instances.
Historical test jobs receive a central gated tag such as `history-tests`, so
normal CI does not execute them. A direct selection still requires enabling the
tag. Other expensive properties add their own tags rather than replacing the
history tag.

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
  commands = [commands.curl commands.coreutils];

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

  script = ''
    curl "$TEST_ENDPOINT/health"
  '';
}
```

The harness installs cleanup handling before setup, runs teardown after success,
failure, or interruption, and keeps setup and teardown in the same host shell.
Only named environment variables, capabilities, and mounts cross into the guest.

Host shell remains appropriate for native fixtures, host comparisons, and
runtime coordination. WASIX shell is preferred when the behavior under test is a
workflow intended to run entirely inside WASIX.

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
- package, artifact, test, and job addresses are unique;
- generated check outputs merge disjointly;
- aliases resolve to one canonical entry and cannot shadow another address;
- `ci.jobs` and `ci.catalog.jobs` have identical keys;
- every serialized catalog carries the project schema version.

Before the directory loader is adopted, an eval-only prototype must confirm that
deriving multi-package unit names from their result does not introduce a Nix
fixpoint cycle. If it does, the unit constructor must derive the names and
overlay from one declaration; callers must not maintain duplicate lists.
