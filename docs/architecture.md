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
nothing else sets those. `preferredProfilePackages.<name>` is each package at its
preferred profile, used for cross-profile runtime dependencies: git runs
bash, bash only builds in `off`, so git references `preferredProfilePackages.bash`
(`nixpkgsByProfile.exnrefEh.bash` fails on purpose).

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

## 6. Cargo overlay registry (`pkgs/cargo-registry/`)

The wasix rust builds carry their fork content as source patches
(`pkgs/lib/wasix-crate-patches/`). Every rust build, `buildRustPackage` CLI or
maturin/setuptools-rust wheel, gets its crates through
`fetchCargoVendor`/`importCargoLock`, so the wasix `rustPlatform`
(`set/rust-platform.nix`) wraps those to bake the patches into the vendored
tree at vendor time (`apply-vendor-patches.sh`), one mechanism for every builder
instead of a build-time hook. Each wrapper reads its vendor's crate set at eval
(an IFD) and materializes only the patches for crates present, so editing one
crate's patch only rebuilds vendors that contain it. Each package's own
vendoring choice is kept (converting `fetchCargoVendor` to the granular
`importCargoLock` form for cross-package crate sharing was tried and dropped:
its per-crate structure is deeper to evaluate and overflowed nix's eval stack on
the full python-registry closure). Two vendor shapes:

- `importCargoLock` fetches each crate as its own `fetchCrate` derivation
  (shared across the whole rust set); `patchFarm` mirrors that as a symlink
  farm, materializing only the forked crates, so unpatched crates stay shared
  store paths.
- `fetchCargoVendor`'s one monolithic tree is patched by `patchInPlace`, which
  appends the patch step to the vendor's OWN `buildCommand` rather than wrapping
  it. That keeps `fetchCargoVendor`'s inner re-pointable `vendorStaging` FOD,
  which two things reach into: the versioned-history rebase (`load-packages.nix`,
  via the `wasixRebuildVendor` passthru) and packages that relocate a non-root
  lock (cryptography/ddtrace override `vendorStaging.cargoRoot = "src/rust"`). A
  package that re-points `cargoRoot` post-hoc leaves its root vendor unbuildable,
  so it can't be IFD-scoped -- the full patch tree is applied at build time to
  the re-pointed vendor instead.

The wrappers are `lib.makeOverridable` so they keep the functor shape the
cross-splice recurses on.

A fork can add a _new_ crate dependency the consumer's lock lacks (the mio fork
pulls in the `wasix` crate). The fork declares it in its `wasix.nix` `adds`
(collected into `cratePatches.adds`), and injecting it is part of applying the
fork -- the same `apply-vendor-patches.sh`
pass that rewrites the crate's sources also drops the added crate into the vendor
(fetched by its crates.io checksum, with its own `.cargo-checksum.json`) and
writes the line into the vendor `Cargo.lock` via `amend-lock.py`. No package
names it and nothing is wired per-package; every patched vendor gets its declared
deps. Because that pass runs post-FOD (it extends the vendor's `buildCommand`),
the `cargoHash` is untouched -- a fork-carrying wheel keeps nixpkgs' hash. The
lock exists on two sides that nixpkgs' `cargoSetupPostPatchHook` cross-validates
-- the vendor's and the source lock the build's cargo actually reads -- so the
source side is amended by `wasixLockAmendHook` (the vendor is a separate
derivation from the build). Both use the same `amend-lock.py`, a no-op unless a
declared adder crate is present, so they match and run on every build harmlessly.

The overlay cargo registry
(`cargo-registry.wasix.org`) serves the same forks to plain `cargo`, as
`<upstream>+wasix.N` builds, so a project resolves forks by version instead
of `[patch.crates-io]`. `pkgs/cargo-registry/` closes the loop from the
patch tree, so the two can't drift:

- **Mint** (`default.nix` -> `.#cargoRegistry`): the mint publishes one `.crate`
  per version in `crates.json` (upstream crate + floor-selected patch + version
  restamp, repacked deterministically). Versions are the unit; the patch a
  version gets is floor-selected (patches are the fix mechanism, not the mint
  unit). `crates.json` is the version set plus the hashes, generated by
  `nix run .#scripts.crate-pins`, which resolves the crates.io releases matching
  each crate's `edits.nix` `edited` constraint (a semver range: comparator terms,
  comma-AND per element, the array OR-ed, e.g. `libc` `[">=0.2.177, <0.2.189"]`).
  So the registry serves the range the vendor floor-covers; floor-selection fails
  loud where no patch fits, and a resolved version in neither `edited` nor
  `stock` hard-fails, so the coverage is self-checking. A version outside `edited`
  is served stock from crates.io (no shadow limits); git-sourced crates
  (`libdd-*`) are excluded and recorded, since the overlay only shadows crates.io.
  `+wasix.N` numbers come from `rels.json` (shared with the python registry).
- **Server**: the registry server (`wasix-org/cargo-registry`) is a normal
  wasix package -- `overlay/packages/cargo-registry` ->
  `wasmerPackages.wasix-cargo-registry`, cross-built and shipped as a webc, the
  wasm it actually deploys as on Edge (never a native binary). Its dep tree
  builds stock except `reqwest`, which needs the `browserWasm` transform to take
  the native hyper backend instead of browser-fetch. Only its `Cargo.lock` is
  ours: upstream's dogfoods the overlay, resolving every fork as
  `<crate>+wasix.N` from cargo-registry.wasix.org, which `fetchCargoVendor`
  (crates.io) can't fetch. `derive-lock.py` strips the `+wasix.N` suffix off
  every version and dep ref and restores the crates.io checksum, giving
  upstream's exact versions (not re-resolved forward); the vendor-time patches
  re-apply the fork content, so the patch tree must cover those versions
  (`derive-lock.py` prints the `+wasix` crate set to check coverage).
- **Checks** (`.#checks.cargo-registry`): the mint's tarballs are well-formed
  (manifest), cargo resolves a minted `+wasix.N` fork from a directory source
  (consume), and no shadow limit collides with a fork build (shadowLimits). The
  end-to-end serving path is checked with the server package, not here (below).
- **Serve check** (`overlay/packages/cargo-registry/tests/serve.nix`, a test of
  `wasmerPackages.wasix-cargo-registry`): the cross-built wasm server runs under
  wasmer (`--net --volume`), a crate is published through its real publish API,
  and native cargo resolves and compiles it from the server's live sparse index
  over loopback HTTP -- the same wasmer `--net` + loopback pattern the git/curl
  webc tests use, inverted (wasm server, native cargo client). Being a test of
  the server, it fabricates its own minimal one-crate payload (like the git
  test builds a tiny repo) rather than depending on the mint, so it needs no
  wiring beyond the harness (wasmer + the run-by-name shim).
- **Serve** (`.#scripts.cargo-registry-serve`): runs the wasm under wasmer
  (`--net --enable-threads --volume`; `--volume` keeps the fsync rights
  `--mapdir` denies), seeds it from the fresh mint via the real publish API
  (`publish-crate.py`), and leaves it live with crates.io passthrough, for
  building your own projects against the local forks instead of the public
  deployment.

## Flake outputs

- `packages.<system>`: `wasixcc` (default), `cargo-wasix`, `anybuild`,
  `wasix-rust-toolchain`, `wasmer-bin`, `wasix-{libc,llvm,compiler-rt,libcxx,sysroot}`.
- `checks.<system>`: every `passthru.tests`: behavioural suites, toolchain
  suites (`sysroot`, `wasixcc`, `rust`), wheel imports (`wheel-<attr>`),
  per-profile ABI checks (`abi-<profile>`: built artifacts carry the
  profile's EH feature, PIC relocation flavor, and module kind; see
  `pkgs/toolchain/tests/abi-check.nix`), `treefmt`.
- `apps.<system>.update`: the pin updater.
- `legacyPackages.<system>`: the buildable trees, attr path = build target:
  `toolchain.<part>`, `librariesByProfile.<profile>.<lib>`,
  `wasmerPackages.<name>` (with `.pkg`, `.webc`, `.tests`),
  `pythonWheels.<py>.<attr>`;
  plus `nixpkgsByProfile`, `toolchainByProfile`, `pkgsCross`, `allWasmerPackages`.
- `ci`: the same trees flattened to dotted names, so a job name is a build
  path. Unsupported/broken packages are filtered out before becoming jobs.
  `scripts/ci-build.sh` runs it with nix-fast-build and incremental cache
  upload. `scripts/eval-diff.py` diffs the eval (attr to drvPath) against the
  base branch to surface what a PR rebuilds; maps are published to the cache
  bucket (`eval-maps/<rev>.json`) on pushes to main. `scripts/content-diff.py`
  then splits rebuilt outputs into bit-identical vs actually changed
  (narinfo narHash compare; self-referential paths get normalized with `nix
store make-content-addressed`). `scripts/ci-report.py` folds all that and
  the JUnit results into the "Per-package status" check run and a sticky PR
  comment (scripts/post-report.js): posted in-job for same-repo events (the
  bot's pin-bump PRs never fire workflow_run), via test-report.yml for fork
  PRs, where the in-job token is read-only.

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
`passthru.tests` standard nixpkgs · `passthru.pkg` the wasmer package · `passthru.webc` the built webc.
