# The wasix ABI profiles. Each profileSpec is merged into the cross `crossSystem`
# as custom platform fields (wasmExceptions/wasmPic), readable as
# `hostPlatform.wasmExceptions` / `hostPlatform.wasmPic` by set/stdenv.nix.
#
# wasmExceptions: "legacy" | "yes" (exnref) | "no" (off, asyncify) — values are
# what wasixcc's WASIXCC_WASM_EXCEPTIONS expects. wasmPic toggles -fPIC + the PIC
# sysroot variant.
{
  profiles = {
    eh = {wasmExceptions = "legacy";};
    ehpic = {
      wasmExceptions = "legacy";
      wasmPic = true;
    };
    exnrefEh = {wasmExceptions = "yes";};
    exnrefEhpic = {
      wasmExceptions = "yes";
      wasmPic = true;
    };
    # No Wasm-EH: setjmp/longjmp and fork() both go through asyncify (bash).
    off = {wasmExceptions = "no";};
  };

  # The profile shipped binaries are built in by default, and the profile the
  # per-profile library matrix is anchored on. A package that needs a different
  # profile declares it itself via passthru.preferredProfile (e.g. bash -> off);
  # pkgs/default.nix reads that to build preferredPackages.
  defaultProfileName = "exnrefEh";
}
