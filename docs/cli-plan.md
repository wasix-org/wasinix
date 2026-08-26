# Wasinix CLI consolidation roadmap

This file tracks unfinished consolidation work only. The architecture that is
already in force lives in [`architecture.md`](architecture.md),
[`ci.md`](ci.md), and the subsystem documents they link. Remove a roadmap item
when its acceptance criteria land or when the project explicitly drops it.

## One parsed command model

Terminal and pull-request comments already parse through the same Clap tree, and
`cli/surface.rs` exhaustively classifies every command and argument. The comment
path then converts that tree into a second family in `cli/untrusted.rs`:
`UntrustedCommand`, `BisectCommand`, and `MutationCommand`. Presentation,
authorization classification, managed-PR recipes, and dispatch depend on those
parallel types.

Replace that conversion with behavior derived from the parsed `CommandTree` and
its existing argument types. Request normalization may still yield the domain
request types that execution consumes, but it must not recreate the command
grammar as another enum.

Complete when:

- terminal, comment, and CI adapters retain one parsed command type until they
  enter a domain operation;
- classification, effects, presentation, recipes, and dispatch are projections
  of that command rather than matches over a parallel command tree;
- `cli/untrusted.rs` owns only untrusted text handling, if anything remains
  there; and
- the exhaustive surface test fails for every unclassified command or option.

## One process request boundary

`support/tools.rs` owns actual spawning, process groups, timeout, reaping, and
diagnostic tails. Generic update and registry call sites still construct raw
`std::process::Command` values and choose their I/O policy themselves:

- `update/backends.rs`;
- `update/batch.rs`;
- `registries/cargo.rs`; and
- `registries/wasmer.rs`.

Extend the shared process request so those modules state the program, arguments,
working directory, environment, I/O mode, and lifecycle needs without owning a
second execution policy. Keep Nix, Git, and OpenSSH operation construction in
their domain modules, which already delegate their process lifecycle.

Complete when:

- generic `Command` construction is private to the shared process module;
- captured, streamed, and supervised children use one lifecycle and diagnostic
  model;
- cancellation, timeout, output retention, and failed-spawn behavior have shared
  tests; and
- structural enforcement rejects a new raw construction or launch.

## Structural convergence

Several boundaries are still guarded by source scans or substring assertions.
Replace each with visibility, a type, a parsed document, or an evaluated graph
when that boundary can express the rule. Keep a source scan only where Rust,
Nix, or workflow structure cannot enforce the constraint directly, and name that
exception in the owning test.

Complete when every entry in the owner list in
[`architecture.md`](architecture.md#one-place-per-concern-in-the-orchestrator)
has one owner, all known consumers use it, and its strongest practical
enforcement lands with it.

## Rust build boundary

The measured Crane dependency and test split is no longer present after the
project-flake reorganization; `pkgs/overlays/w/wasinix/build.nix` currently uses
one `buildRustPackage` derivation with checks disabled. Re-establish the split
in the current package architecture, or explicitly drop it after repeating the
incremental-build comparison against the current graph.

Complete when the chosen shape has current cold, Rust-source, fixture, and
lock-file measurements; its invalidation boundaries are represented in the Nix
graph; and the current-state build documentation describes it.

## Roadmap completion

This roadmap is empty only when every item above is completed or explicitly
dropped, the complete test suite passes, and any performance claim is backed by
a current remote or CI measurement.
