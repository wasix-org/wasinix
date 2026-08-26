# WASIX Package Repository

A Nix flake that builds software for WASIX (`wasm32-wasix`, a POSIX-flavored
extension of WASI run by Wasmer): the LLVM, libc, wasixcc, Rust, and cargo-wasix
toolchains; cross-compiled C/C++, Rust, and Python packages; and webc packages
for the Wasmer registry.

## Quick start

Wasinix currently supports `x86_64-linux`. You need Git and a Nix installation
with flakes enabled.

```sh
git clone https://github.com/wasix-org/wasinix.git
cd wasinix

nix run .#wasinix -- doctor
nix run .#wasinix -- remote list
nix develop

# example targets under legacyPackages (the system is explicit):
nix build .#legacyPackages.x86_64-linux.packages.wasix.preferred.git # source package
nix build .#legacyPackages.x86_64-linux.artifacts.webc.git         # its WebC
nix build .#legacyPackages.x86_64-linux.packages.native.anybuild   # native package
nix build .#legacyPackages.x86_64-linux.packages.native.wasixcc    # the C/C++ driver
nix build .#legacyPackages.x86_64-linux.packages.wasix.eh.anybuild # WASIX package
nix build .#legacyPackages.x86_64-linux.packages.wasix.exnrefEh.zlib # a library
nix build .#legacyPackages.x86_64-linux.artifacts.wheel-py314.numpy # a wheel
nix build .#legacyPackages.x86_64-linux.artifacts.registry.python # static wheel index

nix run .#wasinix -- update --all         # bump the source pins
```

`doctor` reports configured and missing builders and cache-push credentials.
Configure a builder before starting package or toolchain builds, then use
`wasinix build` or `wasinix spot` with `--on <remote>` as described in
[`docs/building.md`](docs/building.md). The dev shell puts `wasinix`, `wasixcc`,
and `cargo-wasix` on `PATH`.

`legacyPackages.x86_64-linux` exposes the full project for inspection and
one-off development outputs. Use the orchestrator for package, artifact, and CI
builds that need configured routing and a report.

CI builds cataloged packages, artifacts, and tests as separate jobs from
`legacyPackages.<system>.ci.jobs`, driven by the `wasinix` CLI in
`tools/wasinix`. Each job has one canonical catalog address.

## Structure

`pkgs/project/` constructs the schema-versioned package catalog;
`pkgs/project/profiles.nix` and `pkgs/set/` produce five ABI-profile package
sets; `pkgs/overlays/` and `pkgs/python-overlays/` are the registered by-name
inventories; projection rules produce artifacts, commands, and tests. Details:
[`docs/architecture.md`](docs/architecture.md).

## Documentation

### Start contributing

- [`docs/setup.md`](docs/setup.md): first-time setup and `wasinix doctor`
- [`docs/building.md`](docs/building.md): routes, builds, checks, and failures
- [`docs/style.md`](docs/style.md): comments, naming, commits, and code norms

### Add or adapt a package

- [`docs/packaging.md`](docs/packaging.md): C, CLI/WebC, Rust, and Python
  recipes
- [`docs/c.md`](docs/c.md), [`docs/rust.md`](docs/rust.md), and
  [`docs/python.md`](docs/python.md): language-specific toolchains and package
  sets
- [`docs/registry.md`](docs/registry.md): publishing, history, rels, and
  previews

### Maintain the repository

- [`docs/ci.md`](docs/ci.md): the orchestrator and GitHub workflow surfaces
- [`docs/updating.md`](docs/updating.md): pin updates
- [`docs/spot.md`](docs/spot.md): focused toolchain experiments
- [`docs/python-coverage.md`](docs/python-coverage.md): Python ecosystem
  coverage
- [`WASIX-TODO.md`](WASIX-TODO.md): known WASIX and toolchain issues

### Extend Wasinix from another flake

- [`docs/architecture.md`](docs/architecture.md): repository architecture and
  mental model
- [`docs/project-api.md`](docs/project-api.md): structured project and extension
  API
- [`AGENTS.md`](AGENTS.md): additional instructions for coding agents
