# libc: the wasix module is the bulk of the edit and barely moves between
# releases, so it is a payload copied from here rather than a thousand identical
# diff lines in every floor; libc renamed its own `::foo` paths to `crate::foo`
# at 0.2.164, which is the only split. The floors are then just the gates on the
# wasi definitions wasix replaces. Below 0.2.159 the wasi module is a single
# src/wasi.rs, so the payload lands beside it and is declared with a #[path]
# rather than restructuring the module into a directory as the fork builds do.
#
# Each served release carries its own floor: 0.2.189 turns FD_ISSET/FD_SET/
# FD_ZERO into `unsafe fn`, and 0.2.164 leaves fd_set ungated, since its older
# `s!` macro does not carry a cfg through to the generated impls. Versions
# without a floor build stock; extend the upper bound after verifying the patch
# on a newer release (a covered version it no longer fits hard-fails).
{lib, ...}: {
  edited = [
    "=0.2.147"
    "=0.2.151"
    "=0.2.152"
    "=0.2.155"
    "=0.2.156"
    "=0.2.159"
    "=0.2.161"
    "=0.2.164"
    "=0.2.169"
    ">=0.2.177, <0.2.190"
  ];
  stock = ["<0.2.177"];
  forVersion = {
    version,
    floorPatch,
  }: {
    patches = lib.optional (floorPatch != null) floorPatch;
    patchPhase = ''
      cp --no-preserve=mode ${
        if lib.versionAtLeast version "0.2.164"
        then ./wasix/0.2.164.rs
        else ./wasix/pre-0.2.164.rs
      } ${
        if lib.versionAtLeast version "0.2.159"
        then "src/wasi/wasix.rs"
        else "src/wasi_wasix.rs"
      }
    '';
  };
}
