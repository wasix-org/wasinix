# Howard Hinnant's date library. nixpkgs pins a tzdata store path into the source, but
# tzdata does not cross-build to wasi; date's tz unit resolves zoneinfo at runtime.
{
  exposeWasixExtendedPackage,
  packages,
  dropPatchesByNameInfix,
  profileSets,
}: let
  lib = packages.sameProfile.lib;
in
  exposeWasixExtendedPackage {
    passthru.wasix.supportedProfiles = profileSets.withEh;
    cmakeFlags = [(lib.cmakeBool "BUILD_SHARED_LIBS" false)];
    patches = dropPatchesByNameInfix ["zoneinfo"];
  }
