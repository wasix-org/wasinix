# Architecture

Five layers, bottom to top. `pkgs/default.nix` wires them together.

## 1. Toolchain foundation (`pkgs/toolchain/`)

Built upstream-faithfully, mirroring wasix-libc's `build32-general.sh`:

- **LLVM** (`llvm.nix`): the `wasix-org/llvm-project` fork, built the standard
  nixpkgs way with the fork source swapped in. Built once on the host
  (multi-target); it is both the shipped toolchain and the compiler that builds
  the sysroot runtimes. Carries two version numbers: the fork release tag (the
  pin) and the base `llvmVersion` (drives nixpkgs' patch selection — see
  `docs/updating.md`).
- **Sysroot** (`sysroot/`): per profile, build libc (the wasix-libc Makefile) →
  compiler-rt → libc++/libc++abi/libunwind, each staged against the previous
  components, then merged — exactly like build32. The ABI flags come from
  wasix-libc's committed `clang-wasix*.cmake_toolchain` files (single source of
  truth; nothing re-derived in Nix). The combined sysroot has one subdir per
  profile (release-tarball layout); wasixcc selects by EH/PIC.
- **wasixcc** (`wasixcc.nix`): the upstream driver built from source, exposed as
  per-tool makeWrapper wrappers (`wasixcc`, `wasix++`, … — wasixccenv dispatches
  on argv[0]) with the toolchain locations baked in.
- **Rust** (`rust/`): the `wasix-org/rust` fork built from source with `x.py`
  (in-tree LLVM — the fork's WebAssembly lowering patch can't use stock LLVM),
  vendored per-workspace by `vendor.nix`; plus `cargo-wasix`, wrapped with the
  toolchain env and a rustup link preamble.
- **`env.nix`**: the `WASIXCC_*` environment contract as data. Every consumer
  (wasixcc wrappers, cargo-wasix wrapper, the stdenv shim, the devShell/test
  fragments in `dev-env.nix`) renders from it, so they can't drift.

## 2. Profiles → cross sets (`pkgs/profiles.nix`, `pkgs/set/`)

The 5 ABI profiles — `eh`, `ehpic`, `exnrefEh` (default), `exnrefEhpic`, `off` —
are an axis orthogonal to nixpkgs' build/host/target. `profiles.nix` is the
canonical table; the crossSystem platform fields (`wasmExceptions`/`wasmPic`),
the sysroot `{eh, pic, exnref}` encoding, the sysroot subdir names, and the
platform → profile-name lookup (`profileOf`) all derive from it.

Each profile is a **full nixpkgs cross package set** (like `pkgsStatic`):
`set/mk-pkgs.nix` re-imports nixpkgs with the wasix crossSystem and injects the
wasixcc cc-wrapper stdenv via `config.replaceCrossStdenv` (`set/stdenv.nix`).
Consequence: **linked dependencies auto-thread within a profile** — a package
overrides its nixpkgs counterpart and its deps come out wasix-built, no manual
wiring.

Rust is transparent the same way: `set/rust-platform.nix` hands
`makeRustPlatform` a `cargo` shim that routes `cargo build` through cargo-wasix,
and layers wasix defaults on `buildRustPackage` via `lib.extendMkDerivation`
(installs the emitted `.wasm`s, injects the support contract, pins rust-lld as
the linker). It also carries the wasix `maturinBuildHook` for python wheels.
`off`/`exnref*` have no rust std — rust packages are *unsupported* there, via
the contract.

## 3. The overlay (`pkgs/overlay/`)

One flat `packages/` dir holding both libraries and CLIs. Each entry is
`prev.<pkg>` + tweaks via `helpers.libTweaks`. The loader
(`pkgs/lib/load-packages.nix`) implements the one auto-import convention: flat
`<name>.nix` files + `<name>/package.nix` dirs + the `trivial.nix` list — used
by the overlay, by the python set, and (eval-only, via `names`) by
`pkgs/default.nix`, so the enumerations can't drift.

### The support contract

```nix
passthru.wasix = {
  supportedProfiles = [...];   # profiles it TARGETS (default: all;
                               #   helpers.profiles.{all,pic,withoutPic,withEh})
  preferredProfile  = "...";   # profile it SHIPS at (default: repo default if
                               #   supported, else first supported)
  broken = "why + link";       # a DEFECT: should work but currently doesn't
};
```

Semantics: **unsupported** = intentionally not targeted at that profile —
skipped silently by the library matrix and CI, never a failing job (python3 off
ehpic, rust off eh/ehpic, snappy on PIC). **Broken** = should work at its
supported profiles but doesn't (fd, tokei) — visible via `meta.broken`, reason
kept on passthru, and expected to be removed when fixed.

One translator (`applyWasixMeta` in `pkgs/lib/default.nix`, applied uniformly by
the overlay loader) derives `meta.badPlatforms`/`meta.broken` from the contract;
nothing else hand-writes them. Consumers read the contract eval-only:
`supportedIn` filters `libraryMatrix`, `preferredProfileOf` resolves
`preferredPackages.<name>` (each package at its preferred profile — how
cross-profile, non-linked deps are reached, e.g. git embedding
`${preferredPackages.bash}`; `profileSets.exnrefEh.bash` asserts by design).

## 4. Python (`overlay/packages/python3/`, `overlay/python-packages/`)

A dynamic-linking CPython, ehpic-only (dl/ctypes need the PIC sysroot; declared
via the contract). Its `python3.pkgs` set gets wasix build fixes through
`packageOverrides`, auto-imported from `overlay/python-packages/` with the same
loader (plus `pyfinal`/`pyprev` in the callArgs). `python-packages/wheels.nix`
is the shipped-wheel worklist; `pkgs/python-wheels.nix` turns it into build
targets with import smoke-tests (run under wasmer). Shared wheel helpers live in
`python-packages/lib/` (rust/pyo3 plumbing, input filtering).

## 5. The wasmer layer (`pkgs/wasmer/`)

Turns the shipped CLI leaves (`shippedCommands` in `pkgs/default.nix`) into webc
packages, deriving everything from the package (name from `meta.mainProgram`,
version, commands globbed from `bin/*.wasm`); deviations live in
`passthru.wasmer`. `test-lib.nix` is the behavioural harness — tests run the
webc under wasmer and (often) diff against the native tool.

## Flake outputs

- `packages.<system>` — directly-buildable artifacts: `wasixcc` (also
  `default`), `cargo-wasix`, `wasix-rust-toolchain`, `wasmer-bin`, and the
  foundation pieces (`wasix-libc`, `wasix-llvm`, `wasix-compiler-rt`,
  `wasix-libcxx`, `wasix-sysroot`).
- `checks.<system>` — every package's `passthru.tests`, collected uniformly:
  behavioural suites (`bash`, `git`, …), toolchain suites (`sysroot`, `wasixcc`
  = per-profile link/stdenv tests, `rust`), wheel import tests
  (`wheel-<attr>`), `treefmt`.
- `apps.<system>.update` — the pin updater (`docs/updating.md`).
- `legacyPackages.<system>` — everything non-standard. The buildable trees sit
  at top level so their attr path is the build target:
  `foundation.{wasixcc,cargo-wasix,rust-toolchain,libc,compiler-rt,libcxx,sysroot,llvm.clang,llvm.lld,runtime}`,
  `libraryMatrix.<profile>.<lib>`, `shippedPackages.<name>` (carrying `.webc` +
  `.tests`), `pythonWheels.<attr>`; escape hatches `profileSets`, `toolchain`,
  `pkgsCross`, `allWasmer`, `allWasm`.
- **`ci`** — those same trees flattened to dotted keys, so a job name *is* the
  build path (`ci."libraryMatrix.exnrefEh.ncurses"` ↔
  `.#libraryMatrix.exnrefEh.ncurses`), plus `checks.<name>`. Unsupported and
  broken leaves are filtered out before they become jobs. `scripts/ci-build.sh`
  drives it with nix-fast-build + incremental cache upload.

## passthru namespaces

`passthru.wasix.*` — the support contract. `passthru.wasmer.*` — webc config.
`passthru.tests` — standard nixpkgs idiom. `passthru.webc` — the built webc.
