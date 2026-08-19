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
  pkgs.lib.mapAttrs' (attr: _: {
    name = "${attr}-ca";
    value = testLib.mkWasixRun {
      name = "${attr}-ca";
      wasixPkgs = [wasmerPkgs.${attr}];
      script = ''
        php -r '
          $bundle = "/etc/ssl/certs/ca-bundle.crt";
          if (ini_get("curl.cainfo") !== $bundle || ini_get("openssl.cafile") !== $bundle || !is_file($bundle)) {
              exit(1);
          }
        '
      '';
    };
  })
  versions
