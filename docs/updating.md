# Updating pins

```sh
nix run .#update                    # everything
nix run .#update -- --list          # targets + current pins
nix run .#update -- --only llvm wasix-libc
```

`scripts/update.py` bumps the pinned sources of packages this repo defines
(nixpkgs packages follow the nixpkgs input). Derived files (lockfiles, the
rust bootstrap pin, witx pins) are regenerated in the same run.

| target | updates | also regenerates |
|---|---|---|
| `rust-toolchain` | `wasix-org/rust` release | bootstrap pin from the fork's `src/stage0` |
| `cargo-wasix` | `wasix-org/cargo-wasix` release | the committed `Cargo.lock` |
| `wasix-libc` | `wasix-org/wasix-libc` release | the witx spec pins |
| `wasixcc` | `wasix-org/wasixcc` release | |
| `llvm` | fork release tag | |
| `crabsay`, `libffi` | branch head | hashes |
| `nixpkgs`, `wasmer`, `treefmt-nix` | flake inputs | |

## Per-pin notes

**rust-toolchain**: built from source with `x.py`
(`pkgs/toolchain/rust/toolchain.nix`). The hash covers submodules
(`src/llvm-project`); the bootstrap must be exactly the release in the fork's
`src/stage0` (synced automatically). Vendoring derives from in-source
lockfiles, no hash to refill. On a base-Rust bump, review targets/flags
against the fork's `build-wasix.sh`. Check: `nix build
.#wasix-rust-toolchain` (slow), then
`.#legacyPackages.x86_64-linux.shippedPackages.crabsay`.

**llvm**: `tag` is the pin; `llvmVersion` is the base version that selects
nixpkgs' patches. Never bump `llvmVersion` mechanically, only when the fork
rebases onto a newer LLVM. An LLVM bump also rebuilds the sysroot. Check:
`nix build .#wasix-llvm .#wasixcc`.

**cargo-wasix**: upstream has no `Cargo.lock`; the committed one is
regenerated on update (delete it if upstream adds one). Wrapper env belongs
in `pkgs/toolchain/env.nix`. Check: `nix build .#cargo-wasix`, then crabsay.

**wasix-libc**: the witx interface specs are submodules (absent from archive
downloads), pinned separately in `sysroot/libc.nix` and synced on update; a
stale pin fails the build with undeclared `__wasi_*` functions. Patches are
applied on the source (`wasix-libc-pic-tls.patch`); drop any that landed
upstream. Rebuilds everything. Check: `nix build .#wasix-libc` then
`.#wasix-sysroot`, and `.#legacyPackages.x86_64-linux.foundation.sysroot.tests`.

**wasixcc**: the lockfile is in-source, nothing to regenerate. On update,
drop any `wasixcc-*.patch` that landed upstream. Check: `nix build .#wasixcc`
and `.#foundation.wasixcc.tests`.
