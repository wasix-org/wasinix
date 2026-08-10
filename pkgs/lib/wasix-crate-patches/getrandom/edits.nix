# getrandom: the 0.3.x wasi backend is gated on target_env = "p1", which our
# wasm32-wasmer-wasi-dl target (env "dl") misses; the patch widens that gate,
# floored across 0.3.3+ (the patch not fitting a future layout hard-fails). The
# 0.2.x floors are the overlay registry's fork builds instead: a separate backend
# calling the `wasix` crate, which getrandom's upstream Cargo.toml lacks, so it is
# declared in the floor and pulled into consumers' locks through `adds`. The
# requirement spans 0.12 and 0.13 because a consumer may already pin either.
# Releases without a floor build stock.
{
  adds,
  lib,
  ...
}: {
  edited = ["=0.2.7" "=0.2.15" ">=0.3.3"];
  stock = ["<0.2.7" ">0.2.7, <0.2.15" ">0.2.15, <0.3.0"];
  forVersion = {
    version,
    floorPatch,
  }: {
    patches = lib.optional (floorPatch != null) floorPatch;
    adds = lib.optional (lib.versionOlder version "0.3.0") adds.wasix;
  };
}
