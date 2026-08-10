# tokio: the wasi-networking backend patch, floored across 1.47.0+ (a version the
# floor no longer fits hard-fails). Tokio 1.51's target_env = "p1" gates leave
# WASIX's env = "dl" on the supported fd path, so modern versions need only an
# asserted wasm-family rewrite plus any later residual. Below 1.47.0 upstream
# rejects the net/fs/process/signal features on wasm outright, so those versions
# are unvetted rather than stock, even though a sync-only dependent compiles.
# 1.24.x is not served. The overlay registry's fork builds for it carry 1.20.1
# trees under a 1.24 version number, and serving that silently downgrades a
# security forward-port. An honest port splits cleanly -- a 782-line payload
# (src/process/wasi, src/signal/wasi) copied from a patchPhase as mio's backend
# is, plus the tokio_wasi_classic/tokio_wasix cfg split -- but that payload
# targets 1.20's io driver, which 1.24 replaced with crate::runtime::io.
{lib, ...}: {
  edited = ["=1.35.1" ">=1.47.0"];
  forVersion = {
    version,
    floorPatch,
  }: let
    modern = lib.versionAtLeast version "1.51.0";
    hasResidual = lib.versionAtLeast version "1.52.3";
  in {
    patches = lib.optional (!modern || hasResidual) floorPatch;
    patchPhase = lib.optionalString modern ''
      needle='    target_family = "wasm",'
      replacement='    all(target_family = "wasm", not(target_vendor = "wasmer")),'
      matches="$(grep -Fxc "$needle" src/lib.rs)" || {
        status="$?"
        [[ "$status" == 1 ]] || exit "$status"
      }
      if [[ "$matches" != 1 ]]; then
        echo "tokio: expected one wasm-family compile-error gate, found $matches" >&2
        exit 1
      fi
      substituteInPlace src/lib.rs --replace-fail "$needle" "$replacement"
    '';
  };
}
