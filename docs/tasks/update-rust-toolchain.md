# Update WASIX Rust Toolchain

This task updates the pinned prebuilt Rust toolchain downloaded from `wasix-org/rust`.

## Files to update

- `pkgs/toolchain/wasix-rust-toolchain.nix`
- `pkgs/toolchain/default.nix` (only if wiring changes)
- `flake.nix` (only if package exposure changes)

## Steps

1. Choose the new `wasix-org/rust` release tag.
2. Update `version` in `pkgs/toolchain/wasix-rust-toolchain.nix`.
3. Build once with `nix build .#wasix-rust-toolchain` and update `hash` from Nix output if needed.
4. Validate the resulting toolchain binaries are usable:
   - `nix build .#wasix-rust-toolchain`
   - `nix build .#cargo-wasix`
5. Rebuild a dependent package to confirm end-to-end behavior:
   - `nix build .#crabsay`

## Notes

- The package expects the downloaded archive to contain Rust toolchain layout with `bin/` and `lib/rustlib/...`.
- Linux builds rely on `autoPatchelfHook` and runtime libs (for example, `zlib`) to make bundled binaries executable in Nix.
- This repository currently targets `x86_64-linux` for this toolchain setup.
