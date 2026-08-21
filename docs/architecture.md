# Architecture

`pkgs/default.nix` composes the repository from toolchains, profile package
sets, overlays, products, and publishable outputs.

## Toolchains and package sets

`pkgs/toolchain/` builds the language toolchains. `pkgs/profiles.nix` defines
the ABI profiles, and `pkgs/set/mk-pkgs.nix` imports nixpkgs once per profile
with the corresponding WASIX stdenv and language builders.

Each profile is a complete nixpkgs package set. Overriding a dependency there
therefore affects everything in that profile that consumes it. The language
details live in:

- [`c.md`](c.md): LLVM, sysroots, wasixcc, profiles, and the cross stdenv
- [`rust.md`](rust.md): the Rust toolchain, cargo-wasix, crate edits, and the
  cargo registry
- [`python.md`](python.md): CPython, Python package overlays, and wheels

## Products and overlays

`pkgs/products/<name>/package.nix` is the shared recipe for a product built both
natively and with a WASIX host. Its overlay is applied to the native set and,
before the WASIX overlay, to every profile set. The same recipe receives the
appropriate `stdenv`, `rustPlatform`, and dependency splice from its scope.

WASIX-specific policy lives in `pkgs/overlay/`: patches, flags, runtime
dependencies, wasm command names, webc configuration, and tests. An entry
normally adapts `prev.<name>` rather than duplicating its recipe. Entries are
loaded from `trivial.nix`, a flat `<name>.nix`, or `<name>/package.nix` by
`pkgs/lib/load-packages.nix`.

Packages declare support through `passthru.wasix`:

- `supportedProfiles`: profiles the package supports
- `preferredProfile`: its default profile
- `ciProfiles`: the supported subset built continuously
- `broken`: a defect and its reason

`packagesByProfile` exposes every supported build. CI uses the transposed
`ciPackagesByProfile`; it does not define another package taxonomy.
`preferredProfilePackages.<name>` supplies the canonical WASIX build for runtime
dependencies that may use another profile.

## Webc packaging

`pkgs/wasmer/` turns shipped CLIs into webc packages. The default manifest uses
`meta.mainProgram` and the package's `bin/*.wasm`; deviations belong in
`passthru.wasmer`. Shipped entries in `preferredProfilePackages` also expose
their `.pkg`, `.webc`, and `.shim`, plus `.tests` when present; `wasmerPackages`
is the public package namespace and includes explicitly declared aliases. Its
canonical entries alone drive publication, CI, and aggregate generation. Tests
run under Wasmer through `pkgs/wasmer/test-lib.nix`.

## Flake outputs

- `packages.<system>`: convenient development outputs
- `checks.<system>`: package tests plus generated ABI, wheel, and formatting
  checks
- `legacyPackages.<system>`: the complete build trees

The main legacy trees are `toolchain`, `packagesByProfile`, `nativePackages`,
`wasmerPackages`, `pythonWheels`, `pythonRegistry`, `allWasmerPackages`,
`scripts`, and `ci`. `flake.nix` is the exact inventory.

`legacyPackages.<system>.ci` flattens the build trees to dotted job names.
Unsupported and broken packages are filtered before becoming jobs.
`wasinix build` evaluates them once and builds from the evaluated derivations,
and CI runs the same verb.

`packages.<system>.wasinix-core` carries the orchestrator and its Git, Nix,
nix-eval-jobs, and OpenSSH system boundaries. `wasinix` is the compatibility
package that also carries optional registry and publication helpers. The
`wasinix-capability-*` outputs expose each optional helper separately. A core
launcher binds capability resolution to its own flake source and lock; a bare
development binary uses its checkout. Resolution permits substitution or a
remote builder but sets Nix's local build capacity to zero.

CA derivations are not used because caches cannot reliably distribute or
authenticate realisations
([nix#11748](https://github.com/NixOS/nix/issues/11748),
[nix#11393](https://github.com/NixOS/nix/issues/11393)).

## Passthru namespaces

- `passthru.wasix`: profile support and WASIX package policy
- `passthru.wasmer`: webc configuration
- `passthru.tests`: standard nixpkgs tests
- `passthru.pkg` and `passthru.webc`: built Wasmer package outputs

## One place per concern in the orchestrator

Cross-cutting behavior in `tools/wasinix` goes through one module or type per
concern, and the rule is: a call the shared implementation cannot express is a
bug in that implementation. Extend it; never hand-roll the same thing at the
call site. Each of these ships with its own enforcement (rustc visibility where
possible, a source-scanning test in `src/tests/mod.rs` otherwise), so bypassing
one is a compile error or a test failure, not a review comment.

[`cli-plan.md`](cli-plan.md) defines the ordered migration that consolidates
the current CLI onto these boundaries and replaces textual enforcement where a
structural boundary can express the rule.

- `support/env.rs`: the process environment, named accessors only.
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
- `cli/request.rs::drive`: the one prepare-execute-finish path, with
  `cache_policy` as the one cache decision and `ui::emit(JsonArg)` as the one
  machine-output exit. `Effects{Apply,DryRun}` gates every outward writer at the
  write itself.
- `cli/update.rs::MutationMode` + `conclude`: every tree mutation's flags and
  exit; `update/managed.rs` is the managed-PR record.
