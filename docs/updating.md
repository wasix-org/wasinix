# Updating pins

```sh
nix run .#update                    # everything
nix run .#update -- --list          # targets + current pins
nix run .#update -- --only llvm wasix-libc
```

How a pin is bumped is declared next to the pin, as the package's
`passthru.updateScript` (`nix-update-script`, the standard nixpkgs
convention). nix-update resolves the pin's file from `meta.position`, which
the overlay loader stamps to our package files; wrappers point it at their
`passthru.unwrapped` via `updateScript.attrPath` (llvm likewise: its drv
versions are the fork release, while nixpkgs' scope keeps the base LLVM as
release_version for its version gates and source check). `scripts/update.py`
is only the driver: it discovers the declarations by eval, adds the flake-input
targets (no package file to carry a declaration), runs everything isolated,
regenerates derived files after a bump (lockfiles, the rust bootstrap pin,
witx pins; hooks keyed by target name in update.py), and reports the
summary.

Packages can carry `passthru.wasix.updateNotes`: things to check when the
package moves, e.g. a vendored patch that may have landed upstream. Each
note's `when` predicate gets the version from before the change and the
current one; the default fires when the change bumps the package, so the
note shows up exactly in the bump PR (and update run) and nowhere else. A
self-contained predicate (ignoring the arguments, closing over the
package's own bindings) fires on every run until resolved.

| target                  | updates                         | also regenerates                              |
| ----------------------- | ------------------------------- | --------------------------------------------- |
| `rust-toolchain`        | `wasix-org/rust` release        | bootstrap pin from the fork's `src/stage0`    |
| `cargo-wasix`           | `wasix-org/cargo-wasix` release | `cargoHash` (nix-update)                      |
| `wasix-libc`            | `wasix-org/wasix-libc` release  | the witx spec pins                            |
| `wasixcc`               | `wasix-org/wasixcc` release     |                                               |
| `llvm`                  | fork release tag                |                                               |
| `crabsay`               | branch head                     | hashes                                        |
| `nixpkgs`               | flake input                     | stale keys out of `python-registry/rels.json` |
| `wasmer`, `treefmt-nix` | flake inputs                    |                                               |

libffi has no pin: it follows nixpkgs' libffi with the wasix-org fork's wasi
backend vendored as a patch (`packages/libffi/wasi-backend.patch`).

## Per-pin notes

**rust-toolchain**: built from source with `x.py`
(`pkgs/toolchain/rust/toolchain.nix`). The hash covers submodules
(`src/llvm-project`); the bootstrap must be exactly the release in the fork's
`src/stage0` (synced automatically). Vendoring derives from in-source
lockfiles, no hash to refill. On a base-Rust bump, review targets/flags
against the fork's `build-wasix.sh`. Check: `nix build
.#wasix-rust-toolchain` (slow), then
`.#legacyPackages.x86_64-linux.wasmerPackages.crabsay`.

**llvm**: `tag` is the pin; `llvmVersion` is the base version that selects
nixpkgs' patches. Never bump `llvmVersion` mechanically, only when the fork
rebases onto a newer LLVM. An LLVM bump also rebuilds the sysroot. Check:
`nix build .#wasix-llvm .#wasixcc`.

**cargo-wasix**: a standard `buildRustPackage` with a nix-update-managed
`cargoHash`. Wrapper env belongs in `pkgs/toolchain/env.nix`. Check:
`nix build .#cargo-wasix`, then crabsay.

**wasix-libc**: the witx interface specs are submodules (absent from archive
downloads), pinned separately in `sysroot/libc.nix` and synced on update; a
stale pin fails the build with undeclared `__wasi_*` functions. Patches, if
any, are applied on the source via `applyPatches`; drop any that landed
upstream. Rebuilds everything. Check: `nix build .#wasix-libc` then
`.#wasix-sysroot`, and `.#legacyPackages.x86_64-linux.toolchain.sysroot.tests`.

**wasixcc**: the lockfile is in-source, nothing to regenerate. On update,
drop any `wasixcc-*.patch` that landed upstream. Check: `nix build .#wasixcc`
and `.#toolchain.wasixcc.tests`.

**wasmer**: the runtime every behavioural test runs under. flake.nix applies
`patches/wasmer-offline-resolution.patch` (wasmer PR 6768) on top; drop it
once the PR merges. A newer runtime can make `broken`-marked tests start
passing, which fails them loudly (XPASS): remove the markers it names.

**nixpkgs**: moves every `prev.X` package and the stdenv underneath the
overlay; the biggest blast radius, everything rebuilds. Check: the CI set
(`scripts/ci-build.sh`, or start with a few shipped packages and the
toolchain suites).
