# re2 builds its tests and benchmarks by default, taking gbenchmark and gtest as
# build inputs; gbenchmark does not cross-build, and a cross build cannot run
# either suite.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.re2 {
  cmakeFlags = ["-DRE2_BUILD_TESTING=OFF"];
  buildInputs = helpers.dropInputsByName ["gbenchmark" "gtest"];
  doCheck = false;
}
