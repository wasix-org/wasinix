# openjph's exported cmake config hardcodes INTERFACE_INCLUDE_DIRECTORIES to
# $out/include, which a split dev output leaves non-existent.
{
  exposeExtendedPackage,
  profileSets,
}:
exposeExtendedPackage {
  outputs = _: ["out"];
  passthru.wasix.supportedProfiles = profileSets.withEh;
}
