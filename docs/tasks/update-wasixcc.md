# Update wasixcc

This task updates the locally defined `wasixcc` package.

## Files to update

- `pkgs/toolchain/wasixcc.nix`

## Steps

1. Pick the target `wasix-org/wasixcc` commit/release.
2. Update `src.rev` and `src.hash` in `pkgs/toolchain/wasixcc.nix`, and set
   `version` to that commit's `Cargo.toml` `package.version` (it is a pinned
   literal — reading it from the src would be IFD).
3. Build once with `nix build .#wasixcc` and follow hash guidance from Nix for any dependency/hash changes.
4. Validate wrappers and env integration:
   - `nix develop -c which wasixcc`
   - `nix develop -c wasixcc --version`
   - `nix develop -c wasixld --version`

## Notes

- The bin wrappers bake `WASIXCC_LLVM_LOCATION`, `WASIXCC_BINARYEN_LOCATION`,
  and `WASIXCC_SYSROOT_PREFIX` from the shared env contract in
  `pkgs/toolchain/env.nix` (install-dir locations, not `bin/`).
- Binaryen comes from nixpkgs and the sysroot is built from source
  (`pkgs/toolchain/sysroot/`); neither has a separate pin here.
- This setup currently supports `x86_64-linux`.
