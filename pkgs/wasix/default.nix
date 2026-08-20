{
  toolchain,
  nixpkgs,
  preferredProfilePackages,
  wasmerDependencies,
  wasixRunStub,
  nix-update-script,
}: final: prev: let
  lib = prev.lib;
  helpers = import ../lib {inherit lib;};
  profileName = helpers.profileOf prev.stdenv.hostPlatform;
  profileToolchain =
    toolchain
    // {
      flangRt = toolchain.flangRtByProfile.${profileName};
      openmp = toolchain.openmpByProfile.${profileName};
      wasixflang = toolchain.wasixflangByProfile.${profileName};
    };
  loaded = helpers.loadPackageDir {
    dir = ./.;
    trivial = import ./trivial.nix;
    exclude = ["trivial"];
    history = builtins.fromJSON (builtins.readFile ./history.json);
  };
  applyWasixMeta =
    helpers.applyWasixMeta
    profileName
    prev.stdenv.hostPlatform.system;
in
  lib.optionalAttrs (prev.stdenv.hostPlatform.isWasix or false)
  (lib.mapAttrs (_: applyWasixMeta) (loaded.mkPackages {
    callArgs = {
      inherit final prev helpers preferredProfilePackages wasmerDependencies nixpkgs nix-update-script wasixRunStub;
      toolchain = profileToolchain;
    };
    mkTrivial = set: name: helpers.extendPackage set.${name} {};
    trivialPosition = ./trivial.nix;
  }))
