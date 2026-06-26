# The canonical set of wasix overlay package names — flat packages/<name>.nix
# files + packages/<name>/ dirs + the trivial list. Imported by the overlay
# loader and by pkgs/default.nix (preferredPackages / libraryMatrix) so they
# always agree on what "our packages" are.
{lib}: let
  entries = builtins.readDir ./packages;
  files =
    map (lib.removeSuffix ".nix")
    (lib.attrNames (lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) entries));
  dirs = lib.attrNames (lib.filterAttrs (_: t: t == "directory") entries);
in
  files ++ dirs ++ import ./trivial.nix
