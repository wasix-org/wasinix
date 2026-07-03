# Architecture

`pkgs/default.nix` wires five layers together, bottom to top.

## 1. Toolchain (`pkgs/toolchain/`)

All built from source, following the upstream projects' own build scripts.

- `llvm.nix`: the `wasix-org/llvm-project` fork, built with nixpkgs' LLVM
  machinery. Two version numbers: the fork's release tag (the pin) and
  `llvmVersion`, the base version nixpkgs uses to pick its patches (see
  `docs/updating.md`).
- `sysroot/`: per profile, wasix-libc, then compiler-rt, then
  libc++/libc++abi/libunwind, each staged against the previous parts
  (mirrors wasix-libc's `build32-general.sh`). Per-profile compiler flags
  come from cmake toolchain files committed in wasix-libc, not duplicated
  here. Result: one sysroot dir per profile; wasixcc picks at compile time.
- `wasixcc.nix`: the WASIX compiler driver (invokes clang, wasm-ld,
  wasm-opt), one wrapper per tool name since the binary dispatches on
  `argv[0]`.
- `rust/`: the `wasix-org/rust` fork built with `x.py`, including its bundled
  LLVM (the fork's wasm patches aren't in stock LLVM). `vendor.nix` builds
  the offline cargo registry from the fork's lockfiles; `cargo-wasix.nix` is
  the cargo subcommand that drives WASIX builds.
- `env.nix`: all `WASIXCC_*` variables as data; every consumer (wrappers,
  stdenv, dev shell) renders from it.

## 2. Profiles and cross sets (`pkgs/profiles.nix`, `pkgs/set/`)

A profile is one ABI configuration: wasm exception-handling mode plus PIC or
not. Five exist: `eh`, `ehpic`, `exnrefEh` (default), `exnrefEhpic`, `off`.
`off` has no wasm EH; setjmp/longjmp and fork go through asyncify instead
(bash needs this). PIC is what dynamic linking (Python extensions) requires.
`profiles.nix` is the single definition; platform attributes, sysroot flag
encodings, directory names, and the platform-to-name lookup all derive from
it.

`set/mk-pkgs.nix` imports nixpkgs once per profile with a wasixcc stdenv
swapped in (`config.replaceCrossStdenv`, `set/stdenv.nix`). Each profile is a
real nixpkgs package set, so overriding `zlib` fixes everything that links
zlib. `set/rust-platform.nix` does the same for Rust: `cargo build` is routed
through cargo-wasix, `buildRustPackage` gets WASIX defaults, and a maturin
hook covers Python wheels with Rust extensions. Rust only has a std for `eh`
and `ehpic`.

## 3. The package overlay (`pkgs/overlay/`)

`packages/` holds all package definitions; each overrides its nixpkgs
counterpart (`prev.<name>`). Entries are found by
`pkgs/lib/load-packages.nix`: a name in `trivial.nix`, a flat `<name>.nix`,
or a `<name>/package.nix` dir. The same loader produces the package name list
used elsewhere.

Packages declare where they work in `passthru.wasix`: `supportedProfiles`
(default all five; unsupported profiles skip the package silently),
`preferredProfile` (default `exnrefEh`, else the first supported), and
`broken = "reason"` for defects (usage in `docs/packaging.md`).

`applyWasixMeta` translates this into `meta.badPlatforms`/`meta.broken`;
nothing else sets those. `preferredPackages.<name>` is each package at its
preferred profile, used for cross-profile runtime dependencies: git runs
bash, bash only builds in `off`, so git references `preferredPackages.bash`
(`profileSets.exnrefEh.bash` fails on purpose).

## 4. Python (`overlay/packages/python3/`, `overlay/python-packages/`)

CPython is built with dynamic linking so it can load C extensions, which
needs PIC, so python3 is `ehpic`-only. Per-package fixes live in
`overlay/python-packages/` (same conventions, plus `pyfinal`/`pyprev`).
`wheels.nix` lists the shipped wheels; `pkgs/python-wheels.nix` turns it into
build targets with import tests run under Wasmer.

## 5. Webc packaging (`pkgs/wasmer/`)

webc is Wasmer's package format. CLIs in `shippedCommands`
(`pkgs/default.nix`) get a webc generated from the package (name from
`meta.mainProgram`, commands from `bin/*.wasm`); deviations go in
`passthru.wasmer`. `test-lib.nix` runs tests under Wasmer, usually diffing
against the native tool.

## Flake outputs

- `packages.<system>`: `wasixcc` (default), `cargo-wasix`,
  `wasix-rust-toolchain`, `wasmer-bin`, `wasix-{libc,llvm,compiler-rt,libcxx,sysroot}`.
- `checks.<system>`: every `passthru.tests`: behavioural suites, toolchain
  suites (`sysroot`, `wasixcc`, `rust`), wheel imports (`wheel-<attr>`),
  per-profile ABI checks (`abi-<profile>`: built artifacts carry the
  profile's EH feature, PIC relocation flavor, and module kind; see
  `pkgs/toolchain/tests/abi-check.nix`), `treefmt`.
- `apps.<system>.update`: the pin updater.
- `legacyPackages.<system>`: the buildable trees, attr path = build target:
  `foundation.<part>`, `libraryMatrix.<profile>.<lib>`,
  `shippedPackages.<name>` (with `.webc`, `.tests`), `pythonWheels.<attr>`;
  plus `profileSets`, `toolchain`, `pkgsCross`, `allWasmer`, `allWasm`.
- `ci`: the same trees flattened to dotted names, so a job name is a build
  path. Unsupported/broken packages are filtered out before becoming jobs.
  `scripts/ci-build.sh` runs it with nix-fast-build and incremental cache
  upload.

CA derivations were considered (early cutoff would show which rebuilds
actually change outputs) and rejected for now: binary caches cannot serve
the realisations layer, so CA outputs are unsubstitutable from R2
([nix#11748](https://github.com/NixOS/nix/issues/11748), and no third-party
cache server implements it either), `nix copy` does not reliably upload
realisations ([nix#6623](https://github.com/NixOS/nix/issues/6623)),
realisation signatures are not checked on registration
([nix#11393](https://github.com/NixOS/nix/issues/11393)), and non-determinism
produces conflicting realisations across builders while `--check` cannot
detect it in CA mode ([nix#5336](https://github.com/NixOS/nix/issues/5336)).
Revisit when 11748 and 11393 close (milestone:
[ca-derivations stabilisation](https://github.com/NixOS/nix/milestone/35))
and the toolchain is measured reproducible.

## passthru namespaces

`passthru.wasix.*` where it works · `passthru.wasmer.*` webc config ·
`passthru.tests` standard nixpkgs · `passthru.webc` the built webc.
