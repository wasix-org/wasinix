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
    pkgs.lib.nameValuePair "${attr}-opcache" (testLib.mkWasixRun {
      name = "${attr}-opcache";
      wasixPkgs = [wasmerPkgs.${attr}];
      script = ''
        printf '%s\n' '<?php return 42;' > opcache-target.php
        php -d opcache.error_log=/dev/stderr -d display_startup_errors=1 -r '
          $path = getcwd() . "/opcache-target.php";
          if (!function_exists("opcache_get_status")) {
            throw new RuntimeException("opcache API missing");
          }
          if (opcache_get_status(false) === false) {
            throw new RuntimeException(json_encode([
              "opcache.enable" => ini_get("opcache.enable"),
              "opcache.enable_cli" => ini_get("opcache.enable_cli")
            ]));
          }
          if (!opcache_compile_file($path) || !opcache_is_script_cached($path)) {
            throw new RuntimeException("opcache did not cache script");
          }
          echo "php opcache ok\n";
        '
      '';
    }))
  versions
