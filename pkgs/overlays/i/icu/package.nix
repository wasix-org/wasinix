{exposePackages}: let
  versions = import ./versions.nix;
in
  exposePackages (["icu"] ++ map (version: "icu${version}") versions)
