# Microsoft GSL. Its gtest suite cross-builds a no-exceptions target the wasix pic
# profile rejects, and uses EXPECT_DEATH, which wasi lacks.
{
  exposeWasixExtendedPackage,
  profileSets,
}:
exposeWasixExtendedPackage {
  cmakeFlags = ["-DGSL_TEST=OFF"];
  passthru.wasix.supportedProfiles = profileSets.all;
}
