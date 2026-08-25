# Howard Hinnant's date library. nixpkgs pins a tzdata store path into the source, but
# tzdata does not cross-build to wasi; date's tz unit resolves zoneinfo at runtime.
{
  profileSets,
  exposeWasixExtendedPackage,
  packages,
  dropPatchesByNameInfix,
}: let
  lib = packages.sameProfile.lib;
in
  exposeWasixExtendedPackage {
    cmakeFlags = [(lib.cmakeBool "BUILD_SHARED_LIBS" false)];
    patches = dropPatchesByNameInfix ["zoneinfo"];
    # date's tz.cpp throws, and the off profile is -fno-exceptions.
    passthru.wasix.supportedProfiles = profileSets.withEh;
  }
