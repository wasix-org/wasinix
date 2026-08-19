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
  pkgs.lib.mapAttrs' (attr: _:
    pkgs.lib.nameValuePair "${attr}-flock" (testLib.mkWasixRun {
      name = "${attr}-flock";
      wasixPkgs = [wasmerPkgs.${attr}];
      script = ''
        php -r '
          file_put_contents("lock", "wasix");
          $owner = fopen("lock", "r+");
          $contender = fopen("lock", "r+");
          if (!flock($owner, LOCK_EX)) {
            throw new RuntimeException("exclusive flock failed");
          }
          if (flock($contender, LOCK_EX | LOCK_NB)) {
            throw new RuntimeException("flock did not exclude a second owner");
          }
          flock($owner, LOCK_UN);
          fclose($contender);
          fclose($owner);
          echo "php flock ok\n";
        '
      '';
    }))
  versions
