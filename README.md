# WASIX Package Repository

A Nix flake that builds software for WASIX (`wasm32-wasix`, a POSIX-flavored
extension of WASI run by Wasmer): the LLVM, libc, wasixcc, Rust, and cargo-wasix
toolchains; cross-compiled C/C++, Rust, and Python packages; and webc packages
for the Wasmer registry.

## Quick start

```sh
nix develop                       # shell with wasixcc + cargo-wasix on PATH

nix build .#legacyPackages.x86_64-linux.packages.native.wasix-sysroot

# example targets under legacyPackages (the system is explicit):
nix build .#legacyPackages.x86_64-linux.packages.preferred.git     # source package
nix build .#legacyPackages.x86_64-linux.artifacts.webc.git         # its WebC
nix build .#legacyPackages.x86_64-linux.packages.native.anybuild   # native shared recipe
nix build .#legacyPackages.x86_64-linux.packages.native.wasixcc    # the C/C++ driver
nix build .#legacyPackages.x86_64-linux.packages.wasix.eh.anybuild # WASIX shared recipe
nix build .#legacyPackages.x86_64-linux.packages.wasix.exnrefEh.zlib # a library
nix build .#legacyPackages.x86_64-linux.artifacts.wheel-py314.numpy # a wheel
nix build .#legacyPackages.x86_64-linux.artifacts.registry.python # static wheel index

nix run .#wasinix -- update --all         # bump the source pins
```

CI builds cataloged packages, artifacts, and tests as separate jobs from
`legacyPackages.<system>.ci.jobs`, driven by the `wasinix` CLI in
`tools/wasinix`. Each job has one canonical catalog address.

## Structure

`pkgs/project/` constructs the schema-versioned package catalog;
`pkgs/project/profiles.nix` and `pkgs/set/` produce five ABI-profile package
sets; `pkgs/shared/`, `pkgs/native/`, `pkgs/wasix/`, and `pkgs/python/` are the
registered overlay lanes; projection rules produce artifacts, commands, and
tests. Details: [`docs/architecture.md`](docs/architecture.md).

## Documentation

| doc                                                  | contents                                     |
| ---------------------------------------------------- | -------------------------------------------- |
| [`docs/setup.md`](docs/setup.md)                     | first-time setup and `wasinix doctor`        |
| [`docs/architecture.md`](docs/architecture.md)       | how the layers fit together                  |
| [`docs/project-api.md`](docs/project-api.md)         | structured project and extension API         |
| [`docs/c.md`](docs/c.md)                             | C/C++ toolchain, profiles, and cross stdenv  |
| [`docs/packaging.md`](docs/packaging.md)             | adding packages: C, CLI/webc, Rust, Python   |
| [`docs/registry.md`](docs/registry.md)               | publishing, version history, rels, previews  |
| [`docs/rust.md`](docs/rust.md)                       | rust builds, crate patches, cargo registry   |
| [`docs/python.md`](docs/python.md)                   | CPython, package overlays, and wheels        |
| [`docs/building.md`](docs/building.md)               | where builds run, building and checking      |
| [`docs/ci.md`](docs/ci.md)                           | the CI command tree and its surfaces         |
| [`docs/python-coverage.md`](docs/python-coverage.md) | python ecosystem coverage status             |
| [`docs/style.md`](docs/style.md)                     | comments, naming, commits, code norms        |
| [`docs/updating.md`](docs/updating.md)               | the pin updater                              |
| [`docs/spot.md`](docs/spot.md)                       | experimenting without rebuilding the world   |
| [`AGENTS.md`](AGENTS.md)                             | extra rules for agents working here          |
| [`WASIX-TODO.md`](WASIX-TODO.md)                     | known WASIX/toolchain issues and workarounds |
