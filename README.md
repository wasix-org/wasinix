# WASIX Package Repository

A Nix flake that builds software for WASIX (`wasm32-wasix`, a POSIX-flavored
extension of WASI run by Wasmer): the LLVM, libc, wasixcc, Rust, and cargo-wasix
toolchains; cross-compiled C/C++, Rust, and Python packages; and webc packages
for the Wasmer registry.

## Quick start

```sh
nix develop                       # shell with wasixcc + cargo-wasix on PATH

nix build .#wasix-sysroot         # the per-profile sysroots

# example targets under legacyPackages (the system is explicit):
nix build .#legacyPackages.x86_64-linux.wasmerPackages.git         # a CLI
nix build .#legacyPackages.x86_64-linux.wasmerPackages.git.webc    # its webc
nix build .#legacyPackages.x86_64-linux.nativePackages.anybuild   # native shared recipe
nix build .#legacyPackages.x86_64-linux.nativePackages.wasixcc    # the C/C++ driver
nix build .#legacyPackages.x86_64-linux.packagesByProfile.eh.anybuild # WASIX shared recipe
nix build .#legacyPackages.x86_64-linux.packagesByProfile.exnrefEh.zlib # a library
nix build .#legacyPackages.x86_64-linux.pythonWheels.py314.numpy    # a wheel
nix build .#legacyPackages.x86_64-linux.pythonRegistry              # static wheel index
nix build .#legacyPackages.x86_64-linux.allWasmerPackages                   # all webcs

nix run .#scripts.update                  # bump the source pins
```

CI builds every package as its own job (`.#legacyPackages.<system>.ci`, driven
by `scripts/ci-build.sh`). A job's dotted name is its build path.

## Structure

`pkgs/toolchain/` builds the toolchain from source; `pkgs/profiles.nix` +
`pkgs/set/` turn it into five ABI profiles, each a full nixpkgs cross package
set; `pkgs/products/` holds product recipes instantiated for both the native
host and WASIX, while `pkgs/overlay/` holds WASIX adaptations and small
overrides of nixpkgs packages; `pkgs/wasmer/` packages CLIs as webc and tests
them under Wasmer. Details: [`docs/architecture.md`](docs/architecture.md).

## Documentation

| doc                                            | contents                                     |
| ---------------------------------------------- | -------------------------------------------- |
| [`docs/architecture.md`](docs/architecture.md) | how the layers fit together                  |
| [`docs/c.md`](docs/c.md)                       | C/C++ toolchain, profiles, and cross stdenv  |
| [`docs/packaging.md`](docs/packaging.md)       | adding packages: C, CLI/webc, Rust, Python   |
| [`docs/registry.md`](docs/registry.md)         | publishing, version history, rels, previews  |
| [`docs/rust.md`](docs/rust.md)                 | rust builds, crate patches, cargo registry   |
| [`docs/python.md`](docs/python.md)             | CPython, package overlays, and wheels        |
| [`docs/building.md`](docs/building.md)         | where builds run, building and checking      |
| [`docs/style.md`](docs/style.md)               | comments, naming, commits, code norms        |
| [`docs/updating.md`](docs/updating.md)         | the pin updater                              |
| [`docs/spot.md`](docs/spot.md)                 | experimenting without rebuilding the world   |
| [`AGENTS.md`](AGENTS.md)                       | extra rules for agents working here          |
| [`WASIX-TODO.md`](WASIX-TODO.md)               | known WASIX/toolchain issues and workarounds |

<!-- wasinix green-report validation, safe to delete -->
