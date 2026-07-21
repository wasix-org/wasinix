# WASIX Package Repository

A Nix flake that builds software for WASIX (`wasm32-wasix`, a POSIX-flavored
extension of WASI run by Wasmer): the toolchain (an LLVM fork, the wasix-libc
sysroot, wasixcc, a Rust fork with cargo-wasix), cross-compiled C/C++, Rust and
Python packages, and webc packages for the Wasmer registry.

## Quick start

```sh
nix develop                       # shell with wasixcc + cargo-wasix on PATH

nix build .#wasixcc               # the C/C++ toolchain (also the default output)
nix build .#wasix-sysroot         # the per-profile sysroots
nix build .#wasix-llvm            # the LLVM fork (slow)

# packages live under legacyPackages (the system is explicit):
nix build .#legacyPackages.x86_64-linux.wasmerPackages.git         # a CLI
nix build .#legacyPackages.x86_64-linux.wasmerPackages.git.webc    # its webc
nix build .#legacyPackages.x86_64-linux.librariesByProfile.exnrefEh.zlib # a library
nix build .#legacyPackages.x86_64-linux.pythonWheels.py314.numpy    # a wheel
nix build .#legacyPackages.x86_64-linux.pythonRegistry              # static wheel index
nix build .#legacyPackages.x86_64-linux.allWasmerPackages                   # all webcs

nix run .#scripts.update                  # bump the source pins
```

CI builds every package as its own job (`.#legacyPackages.<system>.ci`,
driven by `scripts/ci-build.sh`). A job's dotted name is its build path.

## Structure

`pkgs/toolchain/` builds the toolchain from source; `pkgs/profiles.nix` +
`pkgs/set/` turn it into five ABI profiles, each a full nixpkgs cross
package set; `pkgs/overlay/` holds the package definitions (small overrides
of their nixpkgs counterparts), including a dynamic-linking CPython and
wheels; `pkgs/wasmer/` packages CLIs as webc and tests them under Wasmer.
Details: [`docs/architecture.md`](docs/architecture.md).

## Documentation

| doc                                            | contents                                     |
| ---------------------------------------------- | -------------------------------------------- |
| [`AGENTS.md`](AGENTS.md)                       | conventions and rules for making changes     |
| [`docs/architecture.md`](docs/architecture.md) | how the layers fit together                  |
| [`docs/packaging.md`](docs/packaging.md)       | adding packages: C, CLI/webc, Rust, Python   |
| [`docs/updating.md`](docs/updating.md)         | the pin updater                              |
| [`WASIX-TODO.md`](WASIX-TODO.md)               | known WASIX/toolchain issues and workarounds |
