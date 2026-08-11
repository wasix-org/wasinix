# getrandom: the 0.3+ wasi backend is gated on target_env = "p1", which our
# wasm32-wasmer-wasi-dl target (env "dl") misses. wasiPreview1Env widens the
# generated gate and fails if its shape changes. The 0.2.x floors are the
# overlay registry's fork builds instead: a separate backend calling the `wasix`
# crate, which must be added to consumers' locks.
{
  adds,
  lib,
  rewriters,
  ...
}: {
  edited = ["=0.2.7" "=0.2.15" ">=0.3.3"];
  stock = ["<0.2.7" ">0.2.7, <0.2.15" ">0.2.15, <0.3.0"];
  forVersion = {
    version,
    floorPatch,
  }: let
    legacy = lib.versionOlder version "0.3.0";
  in {
    patches = lib.optional legacy floorPatch;
    adds = lib.optional legacy adds.wasix;
    patchPhase = lib.optionalString (!legacy) "${rewriters.wasiPreview1Env}";
  };
}
