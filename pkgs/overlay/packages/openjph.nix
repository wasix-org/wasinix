# openjph's exported cmake config hardcodes INTERFACE_INCLUDE_DIRECTORIES to
# $out/include, which a split dev output leaves non-existent.
{
  prev,
  helpers,
  ...
}:
helpers.libTweaks {
  outputs = _: ["out"];
  passthru.wasix.supportedProfiles = helpers.profiles.withEh;
}
prev.openjph
