# WASIX Package Repository

A Nix flake that builds software for **WASIX** (`wasm32-wasix`) from source — the
toolchain (an LLVM fork + libc + runtimes + sysroot), a set of cross-compiled
packages (C/C++, Rust, Python + wheels), and their **Wasmer/webc** package outputs
(e.g. `pkg/git/wasmer.toml` + `bin/git.wasm`).

## Quick start

```sh
nix develop                       # dev shell with wasixcc + cargo-wasix on PATH

nix build .#wasixcc               # the wasix C/C++ toolchain (the default output)
nix build .#wasix-sysroot         # the multi-variant from-source sysroot
nix build .#wasix-llvm            # the LLVM fork (slow)

# packages + aggregates live under legacyPackages (the system is explicit):
nix build .#legacyPackages.x86_64-linux.shippedPackages.git         # one .wasm leaf
nix build .#legacyPackages.x86_64-linux.shippedPackages.git.webc    # its webc package
nix build .#legacyPackages.x86_64-linux.libraryMatrix.exnrefEh.zlib # one library
nix build .#legacyPackages.x86_64-linux.pythonWheels.numpy          # one python wheel
nix build .#legacyPackages.x86_64-linux.allWasmer                   # the merged registry

nix run .#update                  # bump all source pins
```

CI builds every package independently via the flat `ci` job set
(`.#legacyPackages.<system>.ci`, consumed by `nix-fast-build` in
`scripts/ci-build.sh`); a job's dotted name is its `.#` build path.

## How it fits together

Five layers, bottom to top — the full story is in
[`docs/architecture.md`](docs/architecture.md):

1. **Toolchain foundation** (`pkgs/toolchain/`) — LLVM fork, per-profile
   from-source sysroot (libc + compiler-rt + libc++), `wasixcc`, the rust fork +
   cargo-wasix. Built upstream-faithfully.
2. **Profiles → cross sets** (`pkgs/profiles.nix`, `pkgs/set/`) — 5 ABI profiles
   (`eh`, `ehpic`, `exnrefEh` (default), `exnrefEhpic`, `off`), each a full
   nixpkgs cross set with the wasixcc stdenv injected; linked deps auto-thread.
   Rust builds transparently through the same seam.
3. **The overlay** (`pkgs/overlay/packages/`) — one flat dir; each entry is
   `prev.<pkg>` + tweaks. Where a package works is declared via the
   **`passthru.wasix` support contract** (`pkgs/lib/`).
4. **Python** (`overlay/python-packages/`, `pkgs/python-wheels.nix`) — a
   dynamic-linking CPython (ehpic) + a shipped wheel set with import smoke-tests.
5. **The wasmer layer** (`pkgs/wasmer/`) — shipped CLIs become webc packages,
   config derived from the package; behavioural tests run under wasmer.

## Documentation

| doc | what's in it |
|---|---|
| [`AGENTS.md`](AGENTS.md) | conventions & hard rules for implementing changes (agents start here) |
| [`docs/architecture.md`](docs/architecture.md) | the layer-by-layer deep dive, support contract semantics, flake outputs |
| [`docs/packaging.md`](docs/packaging.md) | adding a package: C library, shipped CLI/webc, Rust, Python override/wheel, tests |
| [`docs/updating.md`](docs/updating.md) | `nix run .#update`, what each pin's regen hook automates, manual fallbacks |
| [`WASIX-TODO.md`](WASIX-TODO.md) | catalog of runtime/toolchain quirks + their in-repo workarounds |
