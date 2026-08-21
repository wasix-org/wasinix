{
  packages,
  pkgs,
}: let
  versions = import ../icu/versions.nix;
  inherit (pkgs) lib;
  mk = v: let
    icu = packages.sameProfile."icu${v}";
    data = packages.sameProfile.stdenvNoCC.mkDerivation {
      pname = "icu-data${v}";
      inherit (icu) version src;
      buildCommand = ''
        tar -xzf "$src" --wildcards "icu/source/data/in/icudt*.dat" icu/LICENSE
        install -Dm444 -t "$out/share/icu/${icu.version}" \
          icu/source/data/in/icudt*.dat icu/LICENSE
      '';
      meta = {
        description = "ICU ${v} locale data archive, mounted at the compiled-in default /share/icu/${icu.version}";
        license = lib.licenses.icu;
      };
      passthru.wasinix.shipped = true;
      # No auto-retention: each icu major is already a first-class attr
      # (icu-data${v}), so a pinned major stays served without minting a
      # history entry when the default alias crosses a major.
      passthru.wasinix.retention = "none";
      passthru.wasmer = {
        commands = [];
        # data-only webc: no command to run, so no liveness smoke; the data
        # is exercised by tests/smoke.nix.
        smokeArgs = [];
        fs."/share/icu/${icu.version}" = "${data}/share/icu/${icu.version}";
      };
    };
  in
    data;
in
  # Follows the default icu major, like the icu alias.
  {icu-data = mk (lib.versions.major packages.sameProfile.icu.version);}
  // lib.genAttrs (map (v: "icu-data${v}") versions) (name: mk (lib.removePrefix "icu-data" name))
