# OpenEXR's bundled OpenJPH is never installed, so a static consumer hits
# undefined ojph:: symbols; the packaged one lands in OpenEXR.pc instead.
{
  profileSets,
  exposeWasixExtendedPackage,
  packages,
}:
exposeWasixExtendedPackage {
  propagatedBuildInputs = [packages.sameProfile.openjph];
  passthru.wasix.supportedProfiles = profileSets.withEh;
}
