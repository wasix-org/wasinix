{
  crossPkgs,
  helpers,
  makeWasmerPackage,
  pkgs,
  testLib,
  ...
}: let
  versions = import ../versions.nix;
  wasmerPkgs = helpers.mkPhpShims "" {inherit crossPkgs makeWasmerPackage;};
in
  pkgs.lib.mapAttrs' (attr: spec:
    pkgs.lib.nameValuePair "${attr}-basic" (testLib.mkWasixRun {
      name = "${attr}-basic";
      wasixPkgs = [wasmerPkgs.${attr}];
      script = ''
        cp ${pkgs.dejavu_fonts.minimal}/share/fonts/truetype/DejaVuSans.ttf font.ttf
        cp ${./behavior.php} behavior.php
        php -d phar.readonly=0 behavior.php ${pkgs.lib.escapeShellArg spec.version} "$WASIX_TEST_ROOT/font.ttf"
      '';
    }))
  versions
