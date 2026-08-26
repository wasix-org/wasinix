# re2 builds its tests and benchmarks by default, taking gbenchmark and gtest as
# build inputs; gbenchmark does not cross-build, and a cross build cannot run
# either suite.
{
  exposeWasixExtendedPackage,
  dropInputsByName,
}:
exposeWasixExtendedPackage {
  cmakeFlags = ["-DRE2_BUILD_TESTING=OFF"];
  buildInputs = dropInputsByName ["gbenchmark" "gtest"];
  doCheck = false;
}
