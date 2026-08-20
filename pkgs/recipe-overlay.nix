{dir}: let
  entries = builtins.readDir dir;
  names =
    builtins.filter
    (name:
      entries.${name}
      == "directory"
      && builtins.pathExists (dir + "/${name}/recipe.nix"))
    (builtins.attrNames entries);
in {
  inherit names;

  overlay = {nativeNixUpdateScript ? null}: final: prev: let
    nix-update-script =
      if nativeNixUpdateScript != null
      then nativeNixUpdateScript
      else final.nix-update-script;
  in
    prev.lib.genAttrs names (name: let
      path = dir + "/${name}/recipe.nix";
    in
      final.callPackage path (
        prev.lib.optionalAttrs
        (builtins.functionArgs (import path) ? nix-update-script)
        {inherit nix-update-script;}
      ));
}
