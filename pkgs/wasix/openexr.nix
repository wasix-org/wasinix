# OpenEXR's bundled OpenJPH is never installed, so a static consumer hits
# undefined ojph:: symbols; the packaged one lands in OpenEXR.pc instead.
{
  final,
  prev,
  helpers,
  ...
}:
helpers.extendPackage prev.openexr {
  propagatedBuildInputs = [final.openjph];
  passthru.wasix.supportedProfiles = helpers.profiles.withEh;
}
