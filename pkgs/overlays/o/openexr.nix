# OpenEXR's bundled OpenJPH is never installed, so a static consumer hits
# undefined ojph:: symbols; the packaged one lands in OpenEXR.pc instead.
{
  exposeWasixExtendedPackage,
  packages,
  profileSets,
}:
exposeWasixExtendedPackage {
  passthru.wasix.supportedProfiles = profileSets.withEh;
  propagatedBuildInputs = [packages.sameProfile.openjph];
}
