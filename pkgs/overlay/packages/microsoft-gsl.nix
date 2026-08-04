# Microsoft GSL. Its gtest suite cross-builds a no-exceptions target the wasix pic
# profile rejects, and uses EXPECT_DEATH, which wasi lacks.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  cmakeFlags = ["-DGSL_TEST=OFF"];
  passthru.wasix.supportedProfiles = helpers.profiles.all;
}
prev.microsoft-gsl
