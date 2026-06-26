# WASIX Package Repository

A Nix flake that builds software for **WASIX** (`wasm32-wasix`) from source — the
toolchain (an LLVM fork + libc + runtimes + sysroot), a set of cross-compiled
packages, and their **Wasmer/webc** package outputs (e.g. `pkg/git/wasmer.toml`
+ `bin/git.wasm`).

## Quick start

```sh
nix develop                       # dev shell with wasixcc + cargo-wasix on PATH

nix build .#wasixcc               # the wasix C/C++ toolchain (the default output)
nix build .#wasix-sysroot         # the multi-variant from-source sysroot
nix build .#wasix-llvm            # the LLVM fork (slow)

# webc packages + aggregates live under legacyPackages (the system is explicit):
nix build .#legacyPackages.x86_64-linux.wasmer.git        # one webc package
nix build .#legacyPackages.x86_64-linux.allWasmer         # the merged registry
nix build .#legacyPackages.x86_64-linux.wasix.shippedPackages.grep   # one .wasm leaf
```

CI builds every package independently via the flat `ci` job set
(`.#legacyPackages.<system>.ci`, consumed by `nix-fast-build` in
`scripts/ci-build.sh`).

## Architecture

Four layers, bottom to top:

1. **Toolchain foundation** (`pkgs/toolchain/`) — built upstream-faithfully (mirrors
   wasix-libc's `build32-general.sh`): the `wasix-org/llvm-project` fork provides
   clang/lld; libc + compiler-rt + libc++ are built per ABI variant, driven by
   wasix-libc's committed `clang-wasix*.cmake_toolchain` files, and merged into a
   sysroot. `wasixcc` wraps it all.

2. **Profiles → cross sets** (`pkgs/profiles.nix`, `pkgs/mk-wasix-*.nix`) — the 5 ABI
   variants (`eh`, `ehpic`, `exnrefEh` (default), `exnrefEhpic`, `off`). Each is a
   **full nixpkgs cross package set** (like `pkgsStatic`) with the wasixcc
   cc-wrapper stdenv injected via `config.replaceCrossStdenv`. Consequence:
   **linked dependencies auto-thread within a profile** — a package just overrides
   its nixpkgs counterpart and its deps come out wasix-built automatically, with no
   manual dependency wiring.

3. **The overlay** (`pkgs/overlay/`) — one flat `packages/` dir holding both
   libraries and CLIs (no library/program split). Each file is `prev.<pkg>` + a few
   tweaks. `lib.nix` provides the helpers (`libTweaks`, `wasmRename`).

4. **The wasmer layer** (`pkgs/wasmer/`) — turns the shipped CLI leaves into webc
   packages, **deriving** everything from the package (name from `meta.mainProgram`,
   version, commands globbed from `bin/*.wasm`, …); per-package deviations live in
   the package's `passthru.wasmer`.

### Key concepts

- **Profiles** are an ABI axis orthogonal to nixpkgs' build/host/target. The default
  is `exnrefEh`; `off` (no Wasm-EH) exists for bash, which needs asyncify'd
  fork/longjmp.
- **Cross-profile deps** use `preferredPackages` (each package at its declared
  preferred profile — `pkgs/profiles.nix` `preferred`, e.g. `bash → off`). This is
  honest and explicit: `profileSets.exnrefEh.bash` asserts rather than silently
  returning the off build. git, for instance, embeds `${preferredPackages.bash}`.
- **`shippedCommands`** (in `pkgs/default.nix`) is the curated list of CLIs that ship
  as webc packages — orthogonal to lib-vs-CLI (curl is both a linked lib and a
  shipped CLI).

## Repository layout

```text
pkgs/
├── default.nix            # central wiring: foundation, profileSets,
│                          #   preferredPackages, the toolchain shim, wasmer, allWasm
├── profiles.nix           # the 5 ABI profiles + default + the cross-profile `preferred` map
├── mk-wasix-stdenv.nix    # the wasixcc cc-wrapper cross stdenv (via replaceCrossStdenv)
├── mk-wasix-pkgs.nix      # build one profile's nixpkgs cross set
├── crabsay.nix            # a Rust/cargo-wasix package (built on the build platform)
├── overlay/
│   ├── default.nix        # the wasix overlay: auto-imports packages/
│   ├── lib.nix            # helpers: libTweaks, wasmRename, mergeScript
│   ├── trivial.nix        # no-tweak packages, just names (→ libTweaks {} prev.X)
│   ├── names.nix          # the canonical package-name set (files + dirs + trivial)
│   └── packages/          # one package per entry — flat file, or a dir if it has assets
│       ├── openssl.nix freetype.nix zlib.nix …    # tweak-only → a single file
│       ├── grep/{package.nix, patches/…, tests/basic.nix}     # has assets → a dir
│       └── gitMinimal/{package.nix, wasix-compat/, tests/…}
├── wasmer/
│   ├── default.nix             # builds shipped webc packages; attaches passthru.tests
│   ├── make-wasmer-package.nix # derive-first webc builder (reads passthru.wasmer)
│   ├── wrap-wasmer-package.nix # the run-by-name stub wrapper (wasmer run --entrypoint)
│   └── test-lib.nix            # behavioural test harness (run under wasmer, diff vs native)
└── toolchain/
    ├── default.nix        # foundation: the from-source compilers + the wrappers
    ├── llvm.nix           # the wasix-org LLVM fork + install tree
    ├── sysroot.nix        # per-variant from-source sysroot (mirrors build32)
    ├── libc.nix compiler-rt.nix libcxx.nix test.nix   # per-component builders + smoke test
    ├── wasixcc.nix cargo-wasix.nix binaryen.nix dev-env.nix   # wrappers + shell env
    └── link-test.nix stdenv-test.nix                  # toolchain tests
```

## Flake outputs

- `packages.<system>` — directly-buildable artifacts: `wasixcc` (also `default`),
  `cargo-wasix`, `wasmer-bin`, and the foundation (`wasix-libc`, `wasix-llvm`,
  `wasix-compiler-rt`, `wasix-libcxx`, `wasix-sysroot`).
- `checks.<system>` — every package's `passthru.tests`, collected uniformly: the
  behavioural suites (`bash`, `git`, …) + the toolchain suites (`sysroot`,
  `wasixcc` — the latter groups the per-profile link/stdenv tests) + `treefmt`.
- `devShells.<system>.default`, `formatter.<system>`.
- `legacyPackages.<system>` — everything non-standard (so `nix flake check` stays
  quiet). The buildable trees sit at top level so their attr path is the build
  target: `toolchain.{wasixcc,cargo-wasix,libc,compiler-rt,libcxx,sysroot,llvm.clang,
  llvm.lld,runtime}`, `libraryMatrix.<profile>.<lib>`, and `shippedPackages.<name>`
  — the wasm cross build, carrying `.webc` (the webc package) and `.tests`. Plus
  escape hatches (`profileSets`, `toolchain`, `pkgsCross`, `allWasmer`/`allWasm`)
  and `ci`.
- **`ci` is those same trees flattened to dotted keys**, so a job name *is* the
  build path: `ci."libraryMatrix.exnrefEh.ncurses"` builds
  `.#libraryMatrix.exnrefEh.ncurses`; `ci."shippedPackages.git.webc"` builds
  `.#shippedPackages.git.webc` (+ `checks.<name>`). The two can't drift.

### passthru conventions

Our markers on a package are namespaced to avoid collisions: `passthru.wasix.*`
for build metadata (e.g. `preferredProfile`), `passthru.wasmer.*` for webc config
(see below). `passthru.tests` stays standard (nixpkgs idiom), and `passthru.webc`
is the package's built webc.

## Adding a package

Pick the lightest form:

- **No tweaks** → add the name to `pkgs/overlay/trivial.nix` (it becomes
  `libTweaks {} prev.<name>`). No file.
- **Tweaks, no assets** → a single `pkgs/overlay/packages/<name>.nix`.
- **Has patches/tests/aux** → a dir `pkgs/overlay/packages/<name>/` with
  `package.nix` + `patches/` + `tests/` + any aux. The loader picks up a flat file
  or a dir automatically.

### A library (linked dependency)

```nix
# pkgs/overlay/packages/foo.nix   (or foo/package.nix)
{ prev, helpers, ... }:
helpers.libTweaks { configureFlags = [ "--disable-bar" ]; } prev.foo
```
`prev.foo` is already built with the wasix cross stdenv, and its linked deps
auto-thread — no manual `self.X`. Use `final.<dep>` for a same-profile dep you
reference explicitly; patches go in `foo/patches/`. It's then available as
`profileSets.<profile>.foo` and (unless shipped) in the per-profile `libraryMatrix`.

### A CLI (shipped as a webc package)

1. As above, but wrap with `wasmRename` to publish `bin/foo` as `foo.wasm` (add
   `asyncifyFlags`/`binaryen` if it needs fork/longjmp), and add `"foo"` to
   `shippedCommands` in `pkgs/default.nix`:
   ```nix
   { prev, helpers, ... }:
   helpers.wasmRename { wasmName = "foo"; } (helpers.libTweaks { } prev.foo)
   ```
2. The webc `wasmer.toml` is derived automatically; only deviations go in the
   package's `passthru.wasmer` — most need none. e.g. git:
   ```nix
   passthru.wasmer = {
     owner = "kilyanni";
     fs."/etc/ssl" = "${final.cacert}/etc/ssl";
     commandEnv.git = { SSL_CERT_FILE = "/etc/ssl/certs/ca-bundle.crt"; };
     autoSelfMount = true;   # mount the /nix/store paths the wasm embeds
   };
   ```
   Other knobs: `name` (defaults to `meta.mainProgram`), `version`, `commands`
   (explicit, for aliases like gunzip→gzip).

### Tests

Drop `pkgs/overlay/packages/<name>/tests/*.nix` (each returns an attrset of
`testLib`-built derivations; a `helpers.nix` is shared setup). They're attached to
the webc package as `passthru.tests` and run under wasmer — see the harness in
`pkgs/wasmer/test-lib.nix` (`mkScriptComparison` diffs against the native tool;
`expectFail`/`broken` mark non-blocking known-issue tests).

## Notes & pitfalls

- `nix build .#…` uses the **git-tracked** flake source — `git add` a new file
  before referencing it (or use `path:$PWD` while iterating).
- Keep patches next to the package set that consumes them
  (`pkgs/overlay/packages/patches/`).
- `bash` and anything off-only build in the `off` profile; building them in another
  profile asserts by design. Reach them via `preferredPackages` / the ship list.
