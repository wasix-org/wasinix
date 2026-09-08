# The toolchain's own compile/link/run tests. They exercise native
# infrastructure rather than a catalog package, so nothing projects them onto an
# entry and the flake registers them as project tests instead. `names` comes from
# the profile table alone because the flake needs the addresses before the
# project exists; only `testsFor` reads that project's package sets.
{lib}: let
  profiles = import ../project/profiles.nix;
  allProfileNames = profiles.profileNames;
  picProfileNames = lib.filter (name: profiles.profiles.${name}.wasmPic or false) allProfileNames;

  # One source for both the names and the derivations; a test that runs on a
  # single profile still names it, so the address says what was covered.
  layout = [
    {
      test = "link";
      file = ../toolchain/tests/link-test.nix;
      profileNames = allProfileNames;
    }
    {
      test = "stdenv";
      file = ../toolchain/tests/stdenv-test.nix;
      profileNames = allProfileNames;
    }
    {
      # a shared library needs -fPIC
      test = "versioned-soname";
      file = ../toolchain/tests/versioned-soname-test.nix;
      profileNames = picProfileNames;
    }
    {
      test = "relocatable-link";
      file = ../toolchain/tests/relocatable-link-test.nix;
      profileNames = [profiles.defaultProfileName];
    }
  ];
  addressOf = test: profileName: "toolchain-${test}-${profileName}";
in {
  names = lib.concatMap (entry: map (addressOf entry.test) entry.profileNames) layout;

  testsFor = {internals, ...}: let
    inherit (internals) packageSets;
    pkgs = packageSets.nativeRaw;
    toolchain = import ../toolchain {inherit pkgs;};
    devEnvFor = import ../toolchain/dev-env.nix {inherit pkgs toolchain;};

    # What the tests read of a profile: the wasixcc env to drive it by hand, the
    # profile itself, and the cross stdenv built with it.
    byProfile =
      lib.mapAttrs (
        profileName: spec: let
          wasmExceptions = spec.wasmExceptions or null;
          pic = spec.wasmPic or false;
        in
          devEnvFor {inherit wasmExceptions pic;}
          // {
            inherit profileName wasmExceptions pic;
            inherit (packageSets.wasixRaw.${profileName}) stdenv;
          }
      )
      profiles.profiles;
  in
    lib.listToAttrs (lib.concatMap (entry:
      map (profileName: {
        name = addressOf entry.test profileName;
        value = pkgs.callPackage entry.file {toolchain = byProfile.${profileName};};
      })
      entry.profileNames)
    layout);
}
