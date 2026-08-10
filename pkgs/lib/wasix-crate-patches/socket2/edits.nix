# socket2: version-pinned wasi backends for the 0.4 and 0.5 lines, Hyper 0.14's
# 0.5.10, and the 0.6.x line. Support was absorbed upstream at 0.6.3, so newer
# 0.6 releases are stock, and upstream emits a `compile_error!` for wasix below
# that, so each served release carries a floor. Releases named here are the ones
# with a fork build to serve; anything else stays uncovered so it fails for a
# fresh port.
#
# src/sys/wasi.rs is most of each edit, and it grows with socket2's own API
# rather than diverging -- 0.5.2 adds RecvFlags' Debug, 0.5.3 the IP_HDRINCL
# re-export, 0.5.5 the msghdr helpers -- so it lives here once as backend/wasi.rs
# with a small delta per release that needs one, and the floors carry only the
# integration hunks.
{lib, ...}: {
  edited = [
    "=0.4.7"
    "=0.4.9"
    "=0.5.0"
    "=0.5.1"
    "=0.5.2"
    "=0.5.3"
    "=0.5.5"
    "=0.5.10"
    ">=0.6.0, <0.6.3"
  ];
  stock = [">=0.6.3"];
  forVersion = {
    version,
    floorPatch,
  }: let
    delta =
      if lib.versionAtLeast version "0.6.0"
      then [./backend/0.6.0.patch]
      else if lib.versionAtLeast version "0.5.10"
      then [./backend/0.5.10.patch]
      else if lib.versionAtLeast version "0.5.5"
      then [./backend/0.5.5.patch]
      else if lib.versionAtLeast version "0.5.3"
      then [./backend/0.5.3.patch]
      else if lib.versionAtLeast version "0.5.2"
      then [./backend/0.5.2.patch]
      else [];
  in {
    patches = lib.optional (floorPatch != null) floorPatch;
    patchPhase = ''
      cp --no-preserve=mode ${./backend/wasi.rs} src/sys/wasi.rs
      ${lib.concatMapStrings (d: "patch -p1 < ${d}\n      ") delta}
    '';
  };
}
