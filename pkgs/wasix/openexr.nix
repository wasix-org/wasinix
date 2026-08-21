# OpenEXR's bundled OpenJPH is never installed, so a static consumer hits
# undefined ojph:: symbols; the packaged one lands in OpenEXR.pc instead.
{
  profileSets,
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  propagatedBuildInputs = [packages.sameProfile.openjph];
  passthru.wasix.supportedProfiles = profileSets.withEh;
}
