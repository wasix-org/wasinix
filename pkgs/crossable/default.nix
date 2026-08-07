# Package recipes instantiated in both the native set and every WASIX profile.
# The directory name is the package attr; target-specific product policy stays
# in overlay/packages, layered over these definitions only for a WASIX host.
let
  dir = ./packages;
  entries = builtins.readDir dir;
  names =
    builtins.filter
    (name:
      entries.${name}
      == "directory"
      && builtins.pathExists (dir + "/${name}/package.nix"))
    (builtins.attrNames entries);
in {
  inherit names;

  overlay = {
    # A cross set's nix-update-script is a target package. Keep update drivers
    # on the native package set rather than taking them from buildPackages.
    nativeNixUpdateScript ? null,
  }: final: prev: let
    nix-update-script =
      if nativeNixUpdateScript != null
      then nativeNixUpdateScript
      else final.nix-update-script;
  in
    prev.lib.genAttrs names (name:
      final.callPackage (dir + "/${name}/package.nix") {
        inherit nix-update-script;
      });
}
