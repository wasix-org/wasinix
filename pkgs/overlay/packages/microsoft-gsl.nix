# Microsoft GSL. Its gtest suite cross-builds a no-exceptions target the wasix pic
# profile rejects, and uses EXPECT_DEATH, which wasi lacks.
{
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.microsoft-gsl {
  cmakeFlags = ["-DGSL_TEST=OFF"];
  passthru.wasix.supportedProfiles = helpers.profiles.all;
  # header-only: ships no static archive to link-smoke.
  passthru.wasix.smokeTest = false;
}
