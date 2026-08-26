# openjph's exported cmake config hardcodes INTERFACE_INCLUDE_DIRECTORIES to
# $out/include, which a split dev output leaves non-existent.
{
  exposeWasixExtendedPackage,
  profileSets,
}:
exposeWasixExtendedPackage {
  passthru.wasix.supportedProfiles = profileSets.withEh;
  outputs = _: ["out"];
}
