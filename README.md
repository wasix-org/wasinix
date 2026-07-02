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
nix build .#legacyPackages.x86_64-linux.shippedPackages.git         # a CLI
nix build .#legacyPackages.x86_64-linux.shippedPackages.git.webc    # its webc
nix build .#legacyPackages.x86_64-linux.libraryMatrix.exnrefEh.zlib # a library
nix build .#legacyPackages.x86_64-linux.pythonWheels.numpy          # a wheel
nix build .#legacyPackages.x86_64-linux.allWasmer                   # all webcs

nix run .#update                  # bump the source pins
```

CI builds every package as its own job (`.#legacyPackages.<system>.ci`,
driven by `scripts/ci-build.sh`). A job's dotted name is its build path.

## Structure

1. `pkgs/toolchain/`: the toolchain, all built from source.
2. `pkgs/profiles.nix`, `pkgs/set/`: five ABI profiles (exception-handling
   mode x PIC); each one is a full nixpkgs cross package set with a
   wasixcc stdenv, so dependencies within a profile resolve automatically.
   Rust builds through the same mechanism via cargo-wasix.
3. `pkgs/overlay/packages/`: the package definitions, each a small override
   of its nixpkgs counterpart. Packages declare which profiles they support
   via `passthru.wasix`.
4. `pkgs/overlay/python-packages/`, `pkgs/python-wheels.nix`: a
   dynamic-linking CPython plus a set of wheels with import tests.
5. `pkgs/wasmer/`: webc packaging and behavioural tests (run under Wasmer).

Details: [`docs/architecture.md`](docs/architecture.md).

## Documentation

| doc | contents |
|---|---|
| [`AGENTS.md`](AGENTS.md) | conventions and rules for making changes |
| [`docs/architecture.md`](docs/architecture.md) | how the layers fit together |
| [`docs/packaging.md`](docs/packaging.md) | adding packages: C, CLI/webc, Rust, Python |
| [`docs/updating.md`](docs/updating.md) | the pin updater and per-pin notes |
| [`WASIX-TODO.md`](WASIX-TODO.md) | known WASIX/toolchain issues and workarounds |
