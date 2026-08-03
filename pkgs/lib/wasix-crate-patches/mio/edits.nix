# mio: a per-release wasi backend (one <version>.patch per line), floored across
# 1.0.3+ so each version takes its line's patch; a version the floor no longer
# fits hard-fails for a fresh patch. The backend calls the `wasix` crate, which
# mio's upstream Cargo.toml lacks; `adds` writes it into consumers' locks and
# vendors so cargo resolves it from crates.io. The pre-1.x line is a different
# backend and builds stock (main builds every 0.x consumer unpatched).
{adds, ...}: {
  edited = [">=1.0.3"];
  stock = ["<1.0.0"];
  forVersion = {floorPatch, ...}: {
    patches = [floorPatch];
    adds = [adds.wasix];
  };
}
