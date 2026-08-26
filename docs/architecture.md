# Architecture

`pkgs/project/wasinix.nix` specializes the public structured project constructor
for this repository. [`project-api.md`](project-api.md) is the v1 contract for
consumers and extensions; this page explains how Wasinix itself uses it.

## Mental model

The flake evaluates one native package set and five WASIX cross package sets.
Each cross set is a profile: a compatible combination of exception handling and
position-independent-code settings. A package unit is a recipe or adaptation
that is evaluated in the package sets where it applies.

The project catalog records those packages once with their supported profiles.
Projection rules derive distributable artifacts, runnable commands, and tests
from catalog entries. CI selects those derived entries by their catalog address.
This separation lets a package declaration state what it supports while shared
rules decide how it is built, tested, and published.

## Toolchains and package sets

`pkgs/project/profiles.nix` is the ABI profile inventory. `mkProject` imports
one native nixpkgs set and one cross set per profile, applying registered
overlays in the same order to every applicable set. `pkgs/toolchain/` constructs
the profile-specific interfaces used by those sets.

Each profile is a complete nixpkgs package set. Overriding a dependency there
therefore affects everything in that profile that consumes it. The language
details live in:

- [`c.md`](c.md): LLVM, sysroots, wasixcc, profiles, and the cross stdenv
- [`rust.md`](rust.md): the Rust toolchain, cargo-wasix, crate edits, and the
  cargo registry
- [`python.md`](python.md): CPython, Python package overlays, and wheels

## Package inventories

The built-in `wasinix` extension is defined in `pkgs/project/extension.nix`. Its
two registered overlays are discovered by `loadPackageOverlays`:

- `packages` applies to native and WASIX nixpkgs sets;
- `python` applies to each supported Python package fixpoint.

Regular entries live under `pkgs/overlays/<first-character>/`. A `package.nix`
defines a complete package and runs in native and WASIX package sets. A flat
`<name>.nix` or directory `wasix.nix` adapts a preceding nixpkgs package only
when the actual host platform is WASIX. This distinction also applies to
nixpkgs' native build-package splices, so WASIX adaptations never leak into host
tools. Patches, tests, and other package inputs stay in the owning directory.
Existing nixpkgs packages requiring no adaptation are registered by the
extension's `inherited` attribute set instead of empty units.

Python adaptations and their history live under
`pkgs/python-overlays/<first-character>/`. Shared Python machinery remains in
`pkgs/python/lib/` and `pkgs/python/wheels/`. Buildable compiler, sysroot, and
repository tools are complete package entries in the same regular inventory;
their role does not create another package category.

Packages declare support through `passthru.wasix`:

- `supportedProfiles`: profiles the package supports
- `preferredProfile`: its default profile
- `broken`: a defect and its reason

CI policy is separate under `passthru.wasinix.ci`; `profiles` selects the
supported subset built continuously. `packages.wasix.<profile>` exposes every
supported build, while `packages.wasix.preferred.<name>` projects each package's
preferred profile. The latter is useful for runtime commands and artifacts but
is not a coherent package set for linked dependencies.

Buildable LLVM, Rust, GHC, wasixcc, sysroot, cargo registry, and anybuild values
are ordinary packages under `packages.native`. Profile-specific stdenvs and
language builders hang from the native package that owns them, for example
`packages.native.wasixcc.profiles.<profile>.stdenv` and
`packages.native.wasi-ghc.haskellPackages`.

## Webc packaging

`pkgs/wasmer/` turns shipped CLIs into WebC packages. The default manifest uses
`meta.mainProgram` and the package's `bin/*.wasm`; deviations belong in
`passthru.wasmer`, while `passthru.wasinix.shipped` opts into publication.
Projection rules map a cataloged package to its package directory and WebC
artifacts, then map the WebC entry to commands and packaged behavior tests. The
global views are `artifacts.pkg.<name>`, `artifacts.webc.<name>`, and
`commands.<name>`. Canonical entries alone drive publication and CI; aliases are
alternate catalog addresses, not duplicate builds.

Entry projections produce versions, artifacts, commands, and tests relative to
one catalog entry. Project projections produce aggregate artifacts from the same
lazy project context. Aggregate artifacts are catalog entries with explicit
immediate subjects, so the ordinary projection machinery attaches their tests
and derives their transitive package subjects for CI. The Python registry is one
such aggregate over the cataloged wheel artifacts; it is not owned by a chosen
interpreter package.

## Flake outputs

- `packages.<system>`: convenient development outputs
- `checks.<system>`: formatting, Nix linters, and project-API evaluation tests
- `legacyPackages.<system>`: the complete structured project

The project exposes `schemaVersion`, `packages`, `artifacts`, `commands`,
`runners`, `harnesses`, `tests`, `catalog`, and `ci`. Repository-only
publication and update projections live under `internals`; consumers must not
depend on them.

`ci.jobs` is a flat map from canonical job address to derivation.
`ci.catalog.jobs` carries the serializable facts for exactly the same keys.
Unsupported, unavailable, and explicitly broken packages remain visible in the
package catalog but do not become CI jobs. The Wasinix CLI owns selector and tag
semantics, records the selected derivations once, and realises those derivations
directly. Nix owns the dependency graph and build schedule; the recorded
evaluation remains the single source of job identity. CI runs the same verb.

`packages.<system>.wasinix-core` carries the orchestrator and its Git, Nix,
nix-eval-jobs, and OpenSSH system boundaries. `wasinix` is the compatibility
package that also carries optional registry and publication helpers. The
`wasinix-capability-*` outputs expose each optional helper separately. A core
launcher binds capability resolution to its own flake source and lock; a bare
development binary may use its PATH and otherwise uses its checkout. Only the
full compatibility launcher marks its optional PATH entries as coming from the
same locked package set; core never prefers ambient helpers. Resolution permits
substitution or a remote builder but sets Nix's local build capacity to zero.

`appsForProject` binds that tool source to a structured project attr. Remote
host runs copy the packaged launcher separately from the project checkout, so an
external project does not need to build or expose its own CLI package to run its
catalog.

After parsing, commands conservatively declare the optional helpers they may
need. One owned background worker realises that set as a batch while command
setup continues. First use waits for the same result; command exit cancels and
reaps unfinished speculation, and an unused prewarm failure does not change the
command result.

Package, artifact, and runtime tests live in the structured project's `tests`
and `ci` views, not in the flake `checks` output. This keeps `nix flake check` a
source-only preflight while `wasinix build` remains the one build orchestrator.

Test constructors live under `pkgs/harnesses/`; package tests receive them
through the project `harnesses` view. Reusable executable adapters that do not
construct a test live under `pkgs/runners/`. Package-specific test declarations
remain beside their package unit.

## Orchestrator build boundary

The main CLI is host-side control-plane software. A helper called by a
foundational derivation has its own narrowly sourced derivation, so an unrelated
CLI edit cannot invalidate every package above it. A leaf helper stays beside
the package or final aggregate that consumes it.

`pkgs/helper-boundaries.toml` classifies every shell, Python, and JavaScript
helper as host, foundational, leaf, or research code. Corpus tests keep that
inventory complete and enforce the source boundary. `cargo-registry-wire` is the
corresponding narrow Rust binary for Cargo protocol work used inside
derivations; it does not pull the main CLI into their closure.

The host CLI uses one Crane graph in `pkgs/overlays/w/wasinix/build.nix`.
`buildDepsOnly` owns third-party and development dependencies, `buildPackage`
owns the production binary, and `cargoTest` owns repository-aware unit tests.
The production source excludes test modules and fixtures. The test source adds
the workflow files and helper inventory that corpus tests inspect. A Rust edit
therefore reuses the dependency artifact, a test fixture changes only the test
derivation, and `Cargo.lock` changes all three nodes.

CA derivations are not used because caches cannot reliably distribute or
authenticate realisations
([nix#11748](https://github.com/NixOS/nix/issues/11748),
[nix#11393](https://github.com/NixOS/nix/issues/11393)).

## Passthru namespaces

- `passthru.wasix`: WASIX compatibility and profile support
- `passthru.wasmer`: Wasmer manifest and runtime package configuration
- `passthru.wasinix`: catalog, checks, CI, retention, publication, and update
  policy

Generated tests and artifacts are catalog projections. They are not maintained
as authoritative `passthru.tests`, `passthru.pkg`, or `passthru.webc` trees.

## One place per concern in the orchestrator

Cross-cutting behavior in `tools/wasinix` goes through one module or type per
concern, and the rule is: a call the shared implementation cannot express is a
bug in that implementation. Extend it; never hand-roll the same thing at the
call site. Each of these ships with its own enforcement (rustc visibility where
possible, a source-scanning test in `src/tests/mod.rs` otherwise), so bypassing
one is a compile error or a test failure, not a review comment.

- `support/env.rs`: the process environment, named accessors only.
- `cli/surface.rs`: terminal and pull-request comments enter one Clap tree; its
  exhaustive policy controls availability, help, and cross-surface errors.
  `cli/untrusted.rs` tokenizes comments and projects authorization,
  presentation, recipes, and domain requests directly from that tree.
- `support/tools.rs::Process`: generic process requests, starts, process groups,
  timeouts, reaping, I/O policy, and bounded diagnostic tails. Nix, Git, and
  OpenSSH keep domain-specific command construction in their owning modules but
  delegate lifecycle operations here.
- `support/capability.rs`: the closed optional-program set and its exact locked
  flake outputs; callers receive executable paths, never choose installables.
- `support/nix.rs::Invocation`: every nix invocation; construction classifies
  the installable, `.route()` applies placement, `.probe(reason)` is the named
  exception for callers that parse failure output. The cache identity constants
  live here, emitted by `wasinix ci nix-config` and copied (test-verified) into
  the `setup-nix` action.
- `support/git.rs` and `nix/builder.rs`: git with the repository named on every
  call; ssh/scp with named deadlines; `Builder::store()` the one ssh-ng
  renderer.
- `support/atoms.rs`: `RunState`/`TaskStatus` render and exit one way;
  `runs::record_started`/`record_finished` pair run.json with its event.
- `ci/exec.rs::finish_task`: the one fragment write and the one PhaseFinished
  emission.
- `github/sanitize.rs::Markdown`: text reaches a GitHub surface only through the
  constructor for the context it lands in; `Markdown::constant` takes `'static`,
  so runtime text cannot skip sanitizing. `Registry::upsert` owns the comment
  budget; `github/client.rs` restricts post/patch to the github module.
- `github/actions.rs`: the scalar GitHub Actions output writer and the workflow
  output and artifact names; parsed-YAML tests pin each consumer field.
- `cli/request.rs::drive`: the one prepare-execute-finish path, with
  `cache_policy` as the one cache decision and `ui::emit(JsonArg)` as the one
  machine-output exit. `Effects{Apply,DryRun}` gates every outward writer at the
  write itself.
- `cli/update.rs::MutationMode` + `conclude`: every tree mutation's flags and
  exit; `update/managed.rs` is the managed-PR record, and `update/snapshot.rs`
  is the typed, tree-keyed Nix view shared by discovery, preflight, hooks, and
  retention.
- `cargo-registry-wire`: the Cargo publish payload and sparse-index record come
  from one normalized-manifest translation. The narrow crate is also the
  derivation-facing binary, so foundational checks never depend on the main CLI.
