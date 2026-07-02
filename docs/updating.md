# Updating pins

```sh
nix run .#update                    # everything
nix run .#update -- --list          # show targets + current pins, no changes
nix run .#update -- --only llvm wasix-libc
```

`scripts/update.py` bumps the source pins of the packages this repo defines (the
ones with their own upstream — `prev.X` nixpkgs passthroughs ride the nixpkgs
pin instead). Three backends: `nix-update` (introspectable flake attrs),
`prefetch` (literal swaps that keep the explanatory comments intact), and
`flake` (`nix flake update <input>`). Derived files ride along via per-target
`regen` hooks — nothing is "regenerate by hand".

| target | what moves | handled automatically |
|---|---|---|
| `rust-toolchain` | `wasix-org/rust` release tag | stage0 bootstrap pin synced from the fork's `src/stage0` |
| `cargo-wasix` | `wasix-org/cargo-wasix` release tag | committed `Cargo.lock` regenerated (upstream ships none) |
| `wasix-libc` | `wasix-org/wasix-libc` release tag | wasi/wasix witx submodule pins synced |
| `llvm` | fork release tag only | — |
| `crabsay` | branch HEAD | src + cargo hashes (nix-update) |
| `libffi` | branch HEAD | src hash |
| `nixpkgs`, `wasmer`, `treefmt-nix` | flake inputs | — |

## Per-pin notes

### rust-toolchain

The fork is built **from source** (`x.py build --stage 2`, in-tree LLVM) — see
`pkgs/toolchain/rust/toolchain.nix`. The submodule-inclusive hash is prefetched
with `nix-prefetch-git --fetch-submodules` (the fork pulls `src/llvm-project`).
The stage0 bootstrap must be the fork's immediate predecessor release, so the
regen hook syncs it exactly from the new tag's `src/stage0`. Crate vendoring
derives from the in-src lockfiles (`toolchain/rust/vendor.nix`) — no FOD hash to
refill. If the fork bumps its base rust version, review the std targets and
configure flags against the fork's `build-wasix.sh` /
`config.toml.wasix-template`.

Validate: `nix build .#wasix-rust-toolchain` (slow), then
`.#legacyPackages.x86_64-linux.shippedPackages.crabsay` end-to-end; the
`checks.rust` hello-world covers the consumer path.

### llvm

`pkgs/toolchain/llvm.nix` carries **two version numbers**: the fork release
`tag` (what the updater bumps) and `llvmVersion` — the *base* LLVM version that
drives nixpkgs' patch selection. **Never bump `llvmVersion` mechanically**; only
when the fork rebases onto a new LLVM, and expect to revisit the
`llvmPackages_NN` scope it overrides. An LLVM bump rebuilds the sysroot too
(compiler-rt/libcxx build from the same monorepo source).

Validate: `nix build .#wasix-llvm .#wasixcc`, `nix develop -c wasixcc --version`.

### cargo-wasix

Upstream ships no `Cargo.lock`; the repo carries one
(`toolchain/rust/cargo-wasix.Cargo.lock`) and vendors from it — the regen hook
refreshes it against the new src. Drop the committed lock once upstream commits
a tracked one. The wrapper env comes from `pkgs/toolchain/env.nix`; keep new env
expectations there.

Validate: `nix build .#cargo-wasix`, then crabsay end-to-end.

### wasix-libc

The sysroot source (`toolchain/sysroot/`). wasix-libc carries the wasi/wasix
witx specs as git submodules (omitted by archive fetches); the header
generators regenerate `api.h` from separately-pinned checkouts, and the regen
hook syncs those pins — stale ones fail the libc build with undeclared
`__wasi_*` functions. The src is wrapped in `applyPatches`
(`wasix-libc-pic-tls.patch`); check whether a new release obsoletes a carried
patch. A libc bump rebuilds every wasix package.

Validate: `nix build .#wasix-libc` (one variant, fast), `.#wasix-sysroot` (all
5), `.#legacyPackages.x86_64-linux.foundation.sysroot.tests`.

### wasixcc (manual — no updater target)

`pkgs/toolchain/wasixcc.nix` pins a commit, not a release. To bump: update
`src.rev` + `src.hash`, and set `version` to that commit's `Cargo.toml`
`package.version` (a pinned literal — reading it from `${src}` would be IFD).
The `Cargo.lock` ships in-source, so dependencies vendor automatically. Check
whether the carried patches (`wasixcc-*.patch`, marked "TODO: upstream") have
landed upstream and can be dropped.

Validate: `nix build .#wasixcc`, `nix develop -c wasixcc --version`, then
`.#foundation.wasixcc.tests` (per-profile link/stdenv suites under wasmer).
