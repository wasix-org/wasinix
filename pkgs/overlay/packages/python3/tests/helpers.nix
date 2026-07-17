# Discovery imports helpers.nix with only pkgs, so wasmerPkgs is passed per
# call site.
{pkgs}: let
  lib = pkgs.lib;
in {
  # Instantiate a test set once per shipped interpreter: the default webc
  # (unsuffixed attrs) and python3.13 ("-313"). f gets {python, pyVer, tag}.
  # The tags are static on purpose: deriving attr names from the shim's
  # .version forces the wasmer package set while its test groups are still
  # being assembled (infinite recursion); pyVer is safe in values only.
  forEachPython = wasmerPkgs: f: let
    instantiate = {
      python,
      tag,
    }:
      lib.mapAttrs' (n: lib.nameValuePair (n + lib.optionalString (tag != "") "-${tag}"))
      (f {
        inherit python tag;
        pyVer = lib.versions.majorMinor python.version;
      });
  in
    instantiate {
      python = wasmerPkgs.python;
      tag = "";
    }
    // instantiate {
      python = wasmerPkgs."python3.13";
      tag = "313";
    };
}
