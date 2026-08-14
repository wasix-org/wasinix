# Architecture

`pkgs/default.nix` composes the repository from toolchains, profile package
sets, overlays, products, and publishable outputs.

## Toolchains and package sets

`pkgs/toolchain/` builds the language toolchains. `pkgs/profiles.nix` defines
the ABI profiles, and `pkgs/set/mk-pkgs.nix` imports nixpkgs once per profile
with the corresponding WASIX stdenv and language builders.

Each profile is a complete nixpkgs package set. Overriding a dependency there
therefore affects everything in that profile that consumes it. The language
details live in:

- [`c.md`](c.md): LLVM, sysroots, wasixcc, profiles, and the cross stdenv
- [`rust.md`](rust.md): the Rust toolchain, cargo-wasix, crate edits, and the
  cargo registry
- [`python.md`](python.md): CPython, Python package overlays, and wheels

## Products and overlays

`pkgs/products/<name>/package.nix` is the shared recipe for a product built both
natively and with a WASIX host. Its overlay is applied to the native set and,
before the WASIX overlay, to every profile set. The same recipe receives the
appropriate `stdenv`, `rustPlatform`, and dependency splice from its scope.

WASIX-specific policy lives in `pkgs/overlay/`: patches, flags, runtime
dependencies, wasm command names, webc configuration, and tests. An entry
normally adapts `prev.<name>` rather than duplicating its recipe. Entries are
loaded from `trivial.nix`, a flat `<name>.nix`, or `<name>/package.nix` by
`pkgs/lib/load-packages.nix`.

Packages declare support through `passthru.wasix`:

- `supportedProfiles`: profiles the package supports
- `preferredProfile`: its default profile
- `ciProfiles`: the supported subset built continuously
- `broken`: a defect and its reason

`packagesByProfile` exposes every supported build. CI uses the transposed
`ciPackagesByProfile`; it does not define another package taxonomy.
`preferredProfilePackages.<name>` supplies the canonical WASIX build for runtime
dependencies that may use another profile.

## Webc packaging

`pkgs/wasmer/` turns shipped CLIs into webc packages. The default manifest uses
`meta.mainProgram` and the package's `bin/*.wasm`; deviations belong in
`passthru.wasmer`. Tests run under Wasmer through `pkgs/wasmer/test-lib.nix`.

## Flake outputs

- `packages.<system>`: convenient development outputs
- `checks.<system>`: package tests plus generated ABI, wheel, and formatting
  checks
- `legacyPackages.<system>`: the complete build trees

The main legacy trees are `toolchain`, `packagesByProfile`, `nativePackages`,
`wasmerPackages`, `pythonWheels`, `pythonRegistry`, `allWasmerPackages`,
`scripts`, and `ci`. `flake.nix` is the exact inventory.

`legacyPackages.<system>.ci` flattens the build trees to dotted job names.
Unsupported and broken packages are filtered before becoming jobs.
`scripts/ci-build.sh` builds and uploads them incrementally.

CA derivations are not used because caches cannot reliably distribute or
authenticate realisations
([nix#11748](https://github.com/NixOS/nix/issues/11748),
[nix#11393](https://github.com/NixOS/nix/issues/11393)).

## Passthru namespaces

- `passthru.wasix`: profile support and WASIX package policy
- `passthru.wasmer`: webc configuration
- `passthru.tests`: standard nixpkgs tests
- `passthru.pkg` and `passthru.webc`: built Wasmer package outputs
