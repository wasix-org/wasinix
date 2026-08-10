# mio: a per-release integration patch plus an extracted wasi backend, one per
# major line; a version the integration patch or expected source layout no longer
# fits hard-fails for a fresh port. The backend calls the `wasix` crate, which
# mio's upstream Cargo.toml lacks; `adds` writes it into consumers' locks and
# vendors so cargo resolves it from crates.io. 0.7.14's published fork is a pure
# restamp, and 0.8.10+ has no fork build at all; both compile stock.
#
# The 0.8 backend moves three times across the line -- 0.8.3 changes the error
# conversion, 0.8.8 makes `log` optional and 0.8.9 cfg-gates the call -- so it is
# one payload with a delta for those releases. mio denies unused_imports and
# dead_code crate-wide, which the backend trips on some releases; relaxing those
# two is one edit here rather than an #[allow] sprinkled through the payload.
{
  adds,
  lib,
  rewriters,
  ...
}: {
  edited = [">=0.8.1, <=0.8.9" ">=1.0.3"];
  stock = ["<0.8.1" ">0.8.9, <1.0.0"];
  forVersion = {
    version,
    floorPatch,
  }: {
    patches = [floorPatch];
    patchPhase =
      if lib.versionOlder version "1.0.0"
      then ''
        rm -r src/sys/wasi
        cp -r --no-preserve=mode ${./backend/0.8} src/sys/wasi
        rm -f src/sys/wasi/*.patch src/sys/wasi/*.toml
        ${
          if lib.versionAtLeast version "0.8.9"
          then "patch -p1 < ${./backend/0.8/0.8.9.patch}"
          else if lib.versionAtLeast version "0.8.8"
          then "patch -p1 < ${./backend/0.8/0.8.8.patch}"
          else if lib.versionAtLeast version "0.8.3" && lib.versionOlder version "0.8.4"
          then "patch -p1 < ${./backend/0.8/0.8.3.patch}"
          else ""
        }
        substituteInPlace src/lib.rs \
          --replace-fail '    unused_imports,' "" \
          --replace-fail '    dead_code' ""
        cat ${./backend/0.8/wasix-dep.toml} >> Cargo.toml
      ''
      else
        lib.optionalString (lib.versionAtLeast version "1.0.3") ''
          if [[ -e src/sys/wasi ]]; then
            if [[ ! -d src/sys/wasi ]] || [[ "$(find src/sys/wasi -mindepth 1 -maxdepth 1 -printf '%f\n')" != mod.rs ]]; then
              echo "mio: expected src/sys/wasi to be absent or contain only mod.rs" >&2
              exit 1
            fi
            rm -r src/sys/wasi
          fi
          cp -r --no-preserve=mode ${./backend/common} src/sys/wasi
          ${lib.optionalString (lib.versionAtLeast version "1.1.0") ''
            cp --no-preserve=mode ${./backend/post-1.0/tcp.rs} src/sys/wasi/tcp.rs
          ''}
          ${lib.optionalString (lib.versionAtLeast version "1.2.0") ''
            cp --no-preserve=mode ${./backend/1.2}/{mod,net}.rs src/sys/wasi/
          ''}
          ${lib.optionalString (lib.versionAtLeast version "1.1.0") ''
            ${rewriters.wasiVendorDeps} 0.13
          ''}
        '';
    adds = [
      (
        if lib.versionOlder version "1.0.0"
        then adds.wasix12
        else adds.wasix
      )
    ];
  };
}
