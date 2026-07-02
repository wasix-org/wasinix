# aiohappyeyeballs for wasix. nixpkgs runs a Sphinx docs pass whose myst-parser doesn't
# cross-build, taking the wheel (and aiohttp) down. Drop the docs (cf. pynacl.nix).
{
  pyprev,
  lib,
  helpers,
  ...
}: let
  wheels = import ./lib/wheels.nix {inherit lib;};
in
  helpers.libTweaks (wheels.dropSphinxDocs ["myst"]) pyprev.aiohappyeyeballs
