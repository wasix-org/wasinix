# Shared recipes instantiated in both the native set and every WASIX profile.
# Sibling directory names are package attrs; WASIX-specific adaptation stays in
# the wasix lane and applies only for a WASIX host.
let
  dir = ./.;
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
    prev.lib.genAttrs names (name: let
      path = dir + "/${name}/package.nix";
    in
      final.callPackage path (
        prev.lib.optionalAttrs
        (builtins.functionArgs (import path) ? nix-update-script)
        {inherit nix-update-script;}
      ));
}
