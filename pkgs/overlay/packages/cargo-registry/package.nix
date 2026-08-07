# The shared recipe consumes upstream's overlay-registry lock after deriving a
# crates.io-compatible copy. The WASIX rustPlatform then applies the fork stack
# at vendor time; this adapter carries only WASIX product policy.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  passthru.wasix = {
    shipped = true;
    # A deployed server, not a version-pinned library.
    retention = "none";
  };
  meta.description = "Overlay cargo registry server, built to WASIX";
}
prev.cargo-registry
