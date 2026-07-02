# Conventions

Rules for changes in this repo. Background: `docs/architecture.md`. How-tos:
`docs/packaging.md`, `docs/updating.md`.

This flake cross-compiles software to WASIX (`wasm32-wasix`, a POSIX-flavored
WASI extension run by Wasmer). The toolchain (LLVM fork, wasix-libc sysroot,
wasixcc, rustc fork + cargo-wasix) is built from source, then used to build
C/C++, Rust, and Python packages, and CLIs are packaged as webc.

```text
pkgs/default.nix     wiring            pkgs/profiles.nix  the ABI profile table
pkgs/lib/            helpers + passthru.wasix machinery
pkgs/set/            per-profile cross sets (stdenv, rustPlatform)
pkgs/toolchain/      llvm.nix, sysroot/, rust/, wasixcc.nix, env.nix, tests/
pkgs/overlay/        packages/, trivial.nix, python-packages/
pkgs/wasmer/         webc packaging + test harness
scripts/update.py    pin updater (nix run .#update)
```

## Rules

- Profiles (`off`, `eh`, `ehpic`, `exnrefEh` = default, `exnrefEhpic`) are
  defined once in `pkgs/profiles.nix`; derive from the table, never restate
  the matrix.
- Where a package works is declared as `passthru.wasix`
  (`supportedProfiles`, `preferredProfile`, `broken = "reason"`; see
  `pkgs/lib/default.nix`). Never set `meta.badPlatforms`/`meta.broken`
  directly.
- Package placement: name in `trivial.nix` / flat `packages/<name>.nix` /
  `packages/<name>/package.nix` dir. Same in `python-packages/`. Only
  `pkgs/lib/load-packages.nix` enumerates these dirs.
- Tweaks go through `helpers.libTweaks` (phases concatenate, lists append,
  attrsets merge, scalars replace, functions get the old value). No
  `(old.X or []) ++ ...` in package files.
- Deps: `final.<dep>` for linking (same profile); `preferredPackages.<name>`
  for tools run at runtime. Never `profileSets.<profile>.<dep>` from a
  package file.
- All `WASIXCC_*`/`CC=wasixcc` environment comes from
  `pkgs/toolchain/env.nix`; never write the exports by hand.
- Patches live next to the file that applies them.
- Pins: `nix run .#update` (`docs/updating.md`).

## Checking your work

- `git add` new files before `nix build`/`nix eval`; the flake only sees
  tracked files.
- `nix fmt` before committing; CI rejects unformatted files.
- Job list: `nix eval .#legacyPackages.x86_64-linux.ci --apply
  builtins.attrNames`. For behaviour-preserving refactors, also diff
  `--apply 'j: builtins.mapAttrs (_: d: d.drvPath) j'` before/after; meta and
  passthru changes don't move drv paths.
- A CI job name is a build path: `nix build .#libraryMatrix.exnrefEh.zlib`,
  `.#shippedPackages.git.webc`, `.#pythonWheels.numpy`.
- Toolchain suites: `.#foundation.wasixcc.tests` (compile+link+run per
  profile), `.#foundation.sysroot.tests`.
- Touching `pkgs/toolchain/` (except `llvm.nix`) rebuilds everything; use a
  remote builder or the CI cache.

## Style

- Commits: `<scope>: <summary>`, lowercase; scopes: `pkgs`, `toolchain`,
  `docs`, `pins`, `tooling`.
- Comments state constraints and reasons, tersely; no narration, no
  em-dashes. Move comments along with code.
- Weird runtime behaviour (exit codes, PATH, `(null):` prefixes, color when
  piped)? Check `WASIX-TODO.md` first; it's likely known, with a workaround.
