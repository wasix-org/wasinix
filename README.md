# WASIX Package Repository

This repository is a Nix flake for building and packaging software for **WASIX**
(`wasm32-wasix`), including:

- plain WASIX build outputs (for example `nano.wasm`)
- Wasmer package outputs (for example `pkg/nano/{wasmer.toml,bin/nano.wasmer}`)

## Goals

- provide a clean, maintainable package layout for WASIX cross-compilation

- Wrap existing nixpkgs packages with WASIX cross-compilation
- Expose plain cross-compiled packages as individual nix packages
- Expose Wasmer packages, which include wasm binaries and wasmer.toml package
  definitions


## Quick Start

- Build all plain WASM binaries:
  - `nix build`
  - same as `nix build .#wasixAll`
- Build one plain package:
  - `nix build .#wasix.nano`
  - `nix build .#wasix.ncurses`
- Build one Wasmer package:
  - `nix build .#wasmer.nano`
- Build all Wasmer packages:
  - `nix build .#wasmerAll`
- Enter development shell:
  - `nix develop`
  The shell has the wasixcc toolchain available

## Flake Outputs

`flake.nix` exposes:

- top-level namespaced package sets (build with `nix build .#...`):
  - `wasix.<name>` (for example `wasix.nano`, `wasix.ncurses`, `wasix.wasixcc`)
  - `wasmer.<name>` (for example `wasmer.nano`, `wasmer.crabsay`)
- system-scoped aggregate bundles:
  - `packages.<system>.wasixAll` (all plain `.wasm` binaries in `result/bin`)
  - `packages.<system>.wasmerAll` (all Wasmer packages in `result/pkg`)
  - `packages.<system>.default` (alias to `wasixAll`)

## Repository Layout

```text
.
├── flake.nix
├── pkgs
│   ├── default.nix                  # central wiring: toolchain, indexes, aggregates
│   ├── toolchain
│   │   ├── default.nix              # local WASIX toolchain index
│   │   ├── wasix-llvm.nix           # pinned WASIX LLVM bundle
│   │   ├── wasixcc.nix              # local wasixcc wrapper package
│   │   ├── binaryen.nix             # pinned Binaryen bundle
│   │   └── wasix-sysroot.nix        # pinned WASIX sysroot artifacts
│   ├── libraries
│   │   ├── default.nix              # library index
│   │   └── ncurses/default.nix      # ncurses WASIX definition
│   ├── programs
│   │   ├── default.nix              # program index
│   │   └── nano
│   │       ├── nano.nix             # plain WASIX package definition
│   │       ├── nanoWasmer.nix       # Wasmer package definition
│   │       └── patches/...          # package-local patches
│   └── wasmer
│       ├── default.nix              # Wasmer package index + aggregate bundle
│       └── make-wasmer-package.nix  # reusable Wasmer package builder function
└── README.md
```

## How It Works

### 1) Toolchain and cross-system setup

`pkgs/default.nix` defines:

- WASIX toolchain components from local `pkgs/toolchain` definitions
- cross configuration (`wasm32-unknown-wasi` with WASIX-specific flags)
- shared env snippets used by package overrides (`toolchainEnv`, `ccEnv`, `commonPreConfigure`)

### 2) Package indexes

- `pkgs/libraries/default.nix` collects library packages
- `pkgs/programs/default.nix` collects binary/program packages
- `pkgs/wasmer/default.nix` collects Wasmer package outputs

This mirrors nixpkgs indexing style while keeping directory depth reasonable.

### 3) Aggregate outputs

- `wasixAll` scans all plain packages for `bin/*.wasm` and copies them into `result/bin`
- `wasmerAll` merges all Wasmer package directories into `result/pkg`

## Wasmer Packaging Model

Wasmer packages are generated via `pkgs/wasmer/make-wasmer-package.nix`.

Defaults:

- `owner = "wasmer"` (overrideable)
- package name in `wasmer.toml` becomes `"{owner}/{name}"`
- description defaults to `package.meta.description` when available (overrideable)
- commands auto-discover from `bin/*.wasm` when `commands = null`

Per-package overrides are implemented in package-specific files such as:

- `pkgs/programs/nano/nanoWasmer.nix`

This keeps custom behavior close to each package.

## Dev Guide: Add a New Package

This section describes the recommended flow for adding a new program package (for example `foo`) and its Wasmer package.

### A. Add the plain package

1. Create `pkgs/programs/foo/foo.nix`
   - start from nixpkgs package via `callPackage`
   - apply WASIX cross tweaks in `overrideAttrs`
   - ensure output binary is named `*.wasm` in `$out/bin` (for aggregate discovery)
2. Add any patches under `pkgs/programs/foo/patches/`
3. Export package from `pkgs/programs/default.nix`:
   - add `foo = pkgsCross.callPackage ./foo/foo.nix { ... };`

### B. Add the Wasmer package

1. Create `pkgs/programs/foo/fooWasmer.nix` using `makeWasmerPackage`
2. In `pkgs/default.nix`, instantiate it with:
   - `foo = programs.foo`
   - `makeWasmerPackage`
3. In `pkgs/wasmer/default.nix`, add a package mapping like `foo = fooWasmer;`
4. In `flake.nix`, it is exposed under `wasmer.<name>` (already wired)

### C. Validate

- `nix build .#wasix.foo`
- `nix build .#wasmer.foo`
- `nix build .#wasixAll`
- `nix build .#wasmerAll`

Check expected output locations:

- plain: `result/bin/*.wasm`
- Wasmer: `result/pkg/foo/wasmer.toml`, `result/pkg/foo/bin/*.wasmer`

## Minimal Templates

### `pkgs/programs/foo/fooWasmer.nix`

```nix
{ makeWasmerPackage, foo }:
makeWasmerPackage {
  package = foo;
  name = "foo";

  # Optional overrides:
  # owner = "your-org";
  # description = "Custom package description";

  # Optional explicit command mapping:
  # commands = [
  #   {
  #     name = "foo";
  #     module = "foo";
  #     wasm = "foo.wasm";
  #     output = "foo.wasmer";
  #   }
  # ];
}
```

### `pkgs/programs/default.nix` (pattern)

```nix
{ nixpkgs, pkgsCross, toolchain, libs }:
{
  nano = pkgsCross.callPackage ./nano/nano.nix {
    inherit nixpkgs toolchain;
    ncurses = libs.ncurses;
  };

  # foo = pkgsCross.callPackage ./foo/foo.nix {
  #   inherit nixpkgs toolchain;
  #   # add dependencies here
  # };
}
```

## Notes and Pitfalls

- `nix build .#...` uses the **git-tracked** flake source. If a new file is untracked, Nix may report that the path does not exist.
  - fix by staging/tracking the file (`git add ...`) before using `.#...`, or use `path:$PWD` while iterating.
- keep patches close to the package that consumes them (`pkgs/programs/<name>/patches/`)
- prefer explicit package-local Wasmer definitions when behavior might diverge later

