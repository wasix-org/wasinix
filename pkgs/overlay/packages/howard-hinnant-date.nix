# Howard Hinnant's date library. nixpkgs pins a tzdata store path into the source, but
# tzdata does not cross-build to wasi; date's tz unit resolves zoneinfo at runtime.
{
  prev,
  helpers,
  final,
  ...
}: let
  lib = final.lib;
in
  helpers.extendPackage prev.howard-hinnant-date {
    cmakeFlags = [(lib.cmakeBool "BUILD_SHARED_LIBS" false)];
    patches = helpers.dropPatchesByNameInfix ["zoneinfo"];
    # date's tz.cpp throws, and the off profile is -fno-exceptions.
    passthru.wasix.supportedProfiles = helpers.profiles.withEh;
  }
