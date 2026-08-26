# The base package consumes upstream's overlay-registry lock after deriving a
# crates.io-compatible copy. The WASIX rustPlatform then applies the fork stack
# at vendor time; this adapter carries only WASIX product policy.
{exposeWasixExtendedPackage}:
exposeWasixExtendedPackage {
  passthru.wasinix = {
    shipped = true;
    # A deployed server, not a version-pinned library.
    retention = "none";
  };
}
