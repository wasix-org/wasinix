# Update wasixcc

This task updates the locally defined `wasixcc` package and its pinned WASIX toolchain dependencies.

## Files to update

- `pkgs/toolchain/wasixcc.nix`
- `pkgs/toolchain/binaryen.nix` (if Binaryen release changes)
- `pkgs/toolchain/wasix-sysroot.nix` (if WASIX sysroot release changes)

## Steps

1. Pick the target `wasix-org/wasixcc` commit/release.
2. Update `src.rev` and `src.hash` in `pkgs/toolchain/wasixcc.nix`.
3. Build once with `nix build .#wasixcc` and follow hash guidance from Nix for any dependency/hash changes.
4. If required by upstream changes, update:
   - Binaryen URL/hash in `pkgs/toolchain/binaryen.nix`
   - Sysroot version/URLs/hashes in `pkgs/toolchain/wasix-sysroot.nix`
5. Validate wrappers and env integration:
   - `nix develop -c which wasixcc`
   - `nix develop -c wasixcc --version`
   - `nix develop -c wasixld --version`

## Notes

- The wrapper script exports `WASIXCC_LLVM_LOCATION`, `WASIXCC_BINARYEN_LOCATION`, and `WASIXCC_SYSROOT_PREFIX`; keep these in sync with package layout expectations.
- This setup currently supports `x86_64-linux`.
