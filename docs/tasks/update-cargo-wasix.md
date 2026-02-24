# Update cargo-wasix

This task updates the pinned `wasix-org/cargo-wasix` source used by the local WASIX toolchain wrapper.

## Files to update

- `pkgs/toolchain/cargo-wasix.nix`
- `pkgs/toolchain/cargo-wasix.Cargo.lock`
- `pkgs/toolchain/default.nix` (only if wiring changes)
- `flake.nix` (only if package exposure changes)

## Steps

1. Pick the new `wasix-org/cargo-wasix` revision (prefer a pinned commit from `main`).
2. Update `src.rev` and `src.hash` in `pkgs/toolchain/cargo-wasix.nix`.
3. Refresh `pkgs/toolchain/cargo-wasix.Cargo.lock` for that exact revision.
4. Build and validate:
   - `nix build .#cargo-wasix`
   - `nix build .#crabsay`
5. If Nix reports hash mismatches, use the provided expected values to update the derivation.

## Notes

- Keep using a pinned commit hash for reproducibility instead of a moving branch ref.
- The wrapper links a rustup-ready toolchain and injects host `cargo` into that toolchain directory.
- `WASM_OPT` should remain overrideable by environment; default fallback points to `${binaryen}/bin/wasm-opt`.
- Keep `pkgs/toolchain/cargo-wasix.Cargo.lock` until upstream `cargo-wasix` commits a tracked `Cargo.lock` in the pinned revision.
