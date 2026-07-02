# Agent & contributor conventions

Terse, imperative rules for implementing changes in this repo. The *why* lives in
`docs/architecture.md`; how-tos in `docs/packaging.md` and `docs/updating.md`.

## What this is

A Nix flake building software for WASIX (`wasm32-wasix`) from source: toolchain
(LLVM fork + libc + sysroot + wasixcc/cargo-wasix), per-profile nixpkgs cross
sets, packages (C/C++, Rust, Python + wheels), and Wasmer/webc outputs.

## Repo map

```text
pkgs/default.nix     central wiring          pkgs/profiles.nix   canonical profile table
pkgs/lib/            shared helpers + the passthru.wasix support contract
pkgs/set/            profile cross-set assembly (stdenv, rustPlatform, mk-pkgs)
pkgs/toolchain/      from-source toolchain: llvm.nix, sysroot/, rust/, wasixcc.nix,
                     env.nix (the WASIXCC_* env contract), tests/
pkgs/overlay/        the package set: packages/, trivial.nix, python-packages/
pkgs/wasmer/         webc packaging + behavioural test harness
scripts/update.py    pin updater (nix run .#update)
```

## Hard rules

- **Support metadata**: a package declares where it works via `passthru.wasix`
  (`supportedProfiles`, `preferredProfile`, `broken = "reason"` — see
  `pkgs/lib/default.nix`). **Never hand-write `meta.badPlatforms` or
  `meta.broken`** — the overlay's one translator (`applyWasixMeta`) derives them.
  Unsupported = intentionally not targeted (silent skip). Broken = defect, with a
  reason string.
- **Terminology**: the ABI axis is a **profile** (`off`, `eh`, `ehpic`,
  `exnrefEh`, `exnrefEhpic`), defined once in `pkgs/profiles.nix`. Everything
  (sysroot variants, platform lookups, profile-set constructors) derives from
  that table — never restate the matrix.
- **Package entries**: no tweaks → name in `overlay/trivial.nix`; tweaks only →
  flat `overlay/packages/<name>.nix`; has patches/tests → dir with
  `package.nix`. The loader (`pkgs/lib/load-packages.nix`) is the only
  enumeration — never `readDir` package dirs elsewhere. Python overrides follow
  the same convention in `overlay/python-packages/`.
- **Tweaks go through `helpers.libTweaks`** (see `extendDrv`): script phases
  CONCATENATE, lists APPEND, attrsets DEEP-MERGE, scalars SET, and a function
  value receives the old value (the escape hatch for filter/replace). Don't
  hand-write `(old.X or []) ++ …` boilerplate in package files.
- **Cross-profile deps**: linked deps auto-thread via `final.<dep>`
  (same profile). Runtime-invoked/non-linked deps use
  `preferredPackages.<name>` (that package at its preferred profile). Never
  reach into `profileSets.<other>.<dep>` from a package file.
- **WASIXCC env**: every `WASIXCC_*`/`CC=wasixcc` environment comes from
  `pkgs/toolchain/env.nix` (rendered via `exportsOf`/`makeWrapperFlagsOf`).
  Never hand-write the exports.
- **Patches** live next to their consumer: `overlay/packages/<name>/patches/`,
  `overlay/python-packages/patches/`, toolchain patches beside their `.nix`.
- **Pins**: bump via `nix run .#update` (see `docs/updating.md`), not by hand,
  unless the pin has no target (wasixcc).

## Verification workflow

- `git add` new files **before** `nix build`/`nix eval` — the flake uses the
  git-tracked tree; untracked files are invisible and eval fails confusingly.
- `nix fmt` before committing (treefmt/alejandra; CI checks it).
- Eval is cheap — use it: the CI job set is
  `nix eval .#legacyPackages.x86_64-linux.ci --apply builtins.attrNames`. For
  refactors, snapshot `--apply 'j: builtins.mapAttrs (_: d: d.drvPath) j'`
  before/after and diff: pure refactors keep job names AND drv hashes identical
  (meta/passthru changes are hash-neutral).
- A job name in `ci` *is* its build path:
  `nix build .#libraryMatrix.exnrefEh.zlib`, `.#shippedPackages.git.webc`,
  `.#pythonWheels.numpy`. Tests: `.#checks.x86_64-linux.<name>` or
  `passthru.tests` on the package.
- Toolchain changes: the end-to-end suites are
  `.#foundation.wasixcc.tests` (per-profile link + stdenv tests, run under
  wasmer) and `.#foundation.sysroot.tests`.
- Anything touching `toolchain/sysroot/` or `wasixcc` rebuilds the world; only
  `foundation.llvm.*` survives. Expect it, use a remote builder / the CI cache.

## Style

- Commit messages: `<scope>: <summary>` lowercase (`pkgs:`, `toolchain:`,
  `docs:`, `pins:`, `tooling:`); body explains the why.
- Comments state constraints the code can't (`why`, upstream links), not
  narration. Keep the existing comment density — files here are deliberately
  heavily annotated; carry comments along when moving code, don't strip them.
- Before debugging a weird wasm failure, check `WASIX-TODO.md` — it catalogs
  known runtime/toolchain quirks (fchdir, PATH resolution, argv[0], isatty,
  wasm-opt-in-configure, …) with their in-repo workarounds.
