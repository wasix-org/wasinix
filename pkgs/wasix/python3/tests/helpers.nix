{pkgs}: let
  inherit (pkgs) lib;
in {
  # Instantiate a test set once per shipped interpreter: the default WebC
  # (unsuffixed attrs) and Python 3.13 ("-313").
  # The tags are static on purpose: deriving attr names from the shim's
  # .version forces the wasmer package set while its test groups are still
  # being assembled (infinite recursion); pyVer is safe in values only.
  forEachPython = preferredPackages: f: let
    instantiate = {
      package,
      tag,
    }:
      lib.mapAttrs' (n: lib.nameValuePair (n + lib.optionalString (tag != "") "-${tag}"))
      (f (builtins.intersectAttrs (builtins.functionArgs f) {
        inherit tag;
        pyVer = lib.versions.majorMinor package.version;
        python = package.artifacts.webc.shim;
        pythonCommands = builtins.attrValues package.artifacts.webc.commands;
      }));
  in
    instantiate {
      package = preferredPackages.python314;
      tag = "";
    }
    // instantiate {
      package = preferredPackages.python313;
      tag = "313";
    };
}
