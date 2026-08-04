# tokio: the wasi-networking backend patch, floored across 1.47.0+ (a version the
# floor no longer fits hard-fails). Tokio 1.51's target_env = "p1" gates leave
# WASIX's env = "dl" on the supported fd path, so modern versions need only an
# asserted wasm-family rewrite plus any later residual. Below 1.47.0 predates
# the port and builds stock as a transitive dep (its net path is not on wasi);
# main builds those consumers unpatched.
{lib, ...}: {
  edited = [">=1.47.0"];
  stock = ["<1.47.0"];
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
