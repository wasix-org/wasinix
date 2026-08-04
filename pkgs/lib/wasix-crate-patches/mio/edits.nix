# mio: small per-release integration patches plus an extracted wasi backend,
# floored across 1.0.3+; a version the integration patch or expected source
# layout no longer fits hard-fails for a fresh port. The backend calls the
# `wasix` crate, which mio's upstream Cargo.toml lacks; `adds` writes it into
# consumers' locks and vendors so cargo resolves it from crates.io. The pre-1.x
# line is a different backend and builds stock (main builds every 0.x consumer
# unpatched).
{
  adds,
  lib,
  rewriters,
  ...
}: {
  edited = [">=1.0.3"];
  stock = ["<1.0.0"];
  forVersion = {
    version,
    floorPatch,
  }: {
    patches = [floorPatch];
    patchPhase = ''
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
    adds = [adds.wasix];
  };
}
