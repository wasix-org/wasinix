# Conventions

Rules for changes in this repo. Background: `docs/architecture.md`. How-tos:
`docs/packaging.md`, `docs/updating.md`, `docs/spot.md`.

This flake cross-compiles software to WASIX (`wasm32-wasix`, a POSIX-flavored
WASI extension run by Wasmer). The toolchain (LLVM fork, wasix-libc sysroot,
wasixcc, rustc fork + cargo-wasix) is built from source, then used to build
C/C++, Rust, and Python packages, and CLIs are packaged as webc.

```text
pkgs/default.nix     wiring            pkgs/profiles.nix  the ABI profile table
pkgs/lib/            helpers + passthru.wasix machinery
pkgs/products/       recipes instantiated natively and for WASIX
pkgs/set/            per-profile cross sets (stdenv, rustPlatform)
pkgs/toolchain/      llvm.nix, sysroot/, rust/, wasixcc.nix, env.nix, tests/
pkgs/overlay/        packages/, trivial.nix, python-packages/
pkgs/wasmer/         webc packaging + test harness
scripts/update.py    pin updater (nix run .#scripts.update)
```

## Rules

- Profiles (`off`, `eh`, `ehpic`, `exnrefEh` = default, `exnrefEhpic`) are
  defined once in `pkgs/profiles.nix`; derive from the table, never restate
  the matrix.
- Where a package works and which variants CI covers is declared as `passthru.wasix`
  (`supportedProfiles`, `preferredProfile`, `ciProfiles`, `broken = "reason"`; see
  `pkgs/lib/default.nix`). Never set `meta.badPlatforms`/`meta.broken`
  directly.
- Package placement: name in `trivial.nix` / flat `packages/<name>.nix` /
  `packages/<name>/package.nix` dir; a dir's `package.nix` may be
  `{names, packages}` for version families (icu). Same in
  `python-packages/`. Only `pkgs/lib/load-packages.nix` enumerates these
  dirs. A package we provide both natively and for WASIX has its standard
  recipe in `pkgs/products/<name>/package.nix`; its WASIX-only
  tweaks and webc policy stay in the matching overlay entry.
- Tweaks go through `helpers.libTweaks` (phases concatenate, lists append,
  attrsets merge, scalars replace, functions get the old value). No
  `(old.X or []) ++ ...` in package files.
- Deps: `final.<dep>` for linking (same profile); `preferredProfilePackages.<name>`
  for tools run at runtime. Never `nixpkgsByProfile.<profile>.<dep>` from a
  package file.
- All `WASIXCC_*`/`CC=wasixcc` environment comes from
  `pkgs/toolchain/env.nix`; never write the exports by hand.
- Patches live next to the file that applies them.
- Pins: `nix run .#scripts.update` (`docs/updating.md`).
- "Recheck/drop this on the next version bump" (a vendored patch, a
  regenerated lock): `passthru.wasix.updateNotes`, which surfaces in the bump
  PR via `scripts/update.py` and the CI report. Not a code comment or
  `WASIX-TODO.md`.
- We control wasmer and the wasix-org forks: root-cause their bugs and
  quirks and suggest an upstream fix rather than only working around them.
  Vendor pending fixes as `.patch` files (placed per the patches rule
  above); when a workaround is needed to ship, track it in `WASIX-TODO.md`
  with the upstream fix identified.
- When starting a nix build, print the build logs and redirect them to a file.
  This helps track down build issues faster without needing to wait for the full
  build to complete, as well as to gauge the progress of long-running builds.

## Remote builds

The toolchain and the full `.ci` sweep are expensive; building them locally is
painful, and a stray system-default builder (e.g. a paid `nixbuild.net`) can
cost real money. Route expensive builds to a remote builder you control.

That builder is machine-specific, so it lives in a gitignored `.remote-builder`
(copy `.remote-builder.example` and fill in host, key, system, features).
`scripts/remote-builder.sh` turns it into ready-made flags; never hardcode a
host or key.
Note that, as it is gitignored, new worktrees may be missing the file.
Check in other worktrees and copy the file over in that case. Tell the user
when you do this.

- `scripts/remote-builder.sh check`: configured and reachable?
- Bulk: `nix-fast-build --skip-cached --flake
.#legacyPackages.x86_64-linux.ci --store "$(scripts/remote-builder.sh
store)"` (local eval, remote build), or `scripts/ci-build-remote.sh` for the
  signed, cache-pushing CI set.
- Single build: `nix build <targets> --max-jobs 0 --builders
"$(scripts/remote-builder.sh builders)" --builders-use-substitutes`.
  `--max-jobs 0` is required, else nix still schedules jobs onto local slots or
  the system default.

Evals (`nix eval`, nix-eval-jobs) run fine locally. Diagnose a remote failure
with `ssh "$(scripts/remote-builder.sh host)"` + `nix log`, not a rebuild.

## Checking your work

- `git add` new files before `nix build`/`nix eval`; the flake only sees
  tracked files.
- `nix fmt` before committing; CI rejects unformatted files.
- Job list: `nix eval .#legacyPackages.x86_64-linux.ci --apply
builtins.attrNames`. For behaviour-preserving refactors, also diff
  `--apply 'j: builtins.mapAttrs (_: d: d.drvPath) j'` before/after; meta and
  passthru changes don't move drv paths.
- A CI job name is a build path: `nix build .#packagesByProfile.exnrefEh.zlib`,
  `.#wasmerPackages.git.webc`, `.#pythonWheels.py314.numpy`.
- Toolchain suites: `.#toolchain.wasixcc.tests` (compile+link+run per
  profile), `.#toolchain.sysroot.tests`; the Rust suite is
  `.#checks.x86_64-linux.rust`.
- Touching `pkgs/toolchain/` (except `llvm.nix`) rebuilds everything; use a
  remote builder or the CI cache. To try such a change on one package first,
  `scripts/spot.sh <profile>.<attr>` rebuilds that attr alone against a cached
  base revision (`docs/spot.md`). Experiments only: it mixes two toolchains, so
  confirm at the root before keeping the change.
- The most thorough check is `nix-fast-build --flake
.#legacyPackages.x86_64-linux.ci --no-link --skip-cached --option
accept-flake-config true`, the same build set as CI
  (`scripts/ci-build.sh`). `--skip-cached` only helps while the change
  avoids mass rebuilds, and those are easy to trigger (anything under
  `pkgs/toolchain/`, a pin bump); expect a huge build that can OOM the
  machine. Do not run it without asking the user first.

## Style

- Commits: `<scope>: <summary>`, lowercase; scopes: `pkgs`, `toolchain`,
  `docs`, `pins`, `tooling`.
- Comments state constraints and reasons, tersely; no narration, no
  em-dashes. Move comments along with code.
- Weird runtime behaviour (exit codes, PATH, `(null):` prefixes, color when
  piped)? Check `WASIX-TODO.md` first; it's likely known, with a workaround.
