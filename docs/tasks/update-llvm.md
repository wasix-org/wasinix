# Update WASIX LLVM

This task updates the pinned WASIX LLVM bundle used by the local toolchain.

## Files to update

- `pkgs/toolchain/wasix-llvm.nix`

## Steps

1. Choose the new `wasix-org/llvm-project` release version.
2. Update `version` in `pkgs/toolchain/wasix-llvm.nix`.
3. Update the download URL if naming changed.
4. Update `hash` (run `nix build .#wasixcc` once; Nix will report the expected hash if mismatched).
5. Validate with:
   - `nix flake check` (if available in this repo)
   - `nix build .#wasixcc`
   - `nix develop -c wasixcc --version`

## Notes

- This repo currently targets `x86_64-linux` for WASIX toolchain artifacts.
- Keep `WASIXCC_LLVM_LOCATION` expectations in sync with wrapper scripts if archive layout changes.
