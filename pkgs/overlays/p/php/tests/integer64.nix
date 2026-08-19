{
  crossPkgs,
  helpers,
  makeWasmerPackage,
  pkgs,
  testLib,
  ...
}: let
  versions = import ../versions.nix;
  wasmerPkgs = helpers.mkPhpShims "-int64" {inherit crossPkgs makeWasmerPackage;};
in
  pkgs.lib.mapAttrs' (attr: _:
    pkgs.lib.nameValuePair "${attr}-int64" (testLib.mkWasixRun {
      name = "${attr}-int64";
      wasixPkgs = [wasmerPkgs.${attr}];
      script = ''
        php -r '
          if (PHP_INT_SIZE !== 8 || PHP_INT_MAX !== 9223372036854775807) {
              throw new RuntimeException("wrong integer range");
          }
          if ((int) "2147483648" !== 2147483648) {
              throw new RuntimeException("32-bit boundary failed");
          }
          if ((new DateTimeImmutable("@4102444800"))->getTimestamp() !== 4102444800) {
              throw new RuntimeException("post-2038 timestamp failed");
          }
          $value = ["integer" => PHP_INT_MAX];
          if (igbinary_unserialize(igbinary_serialize($value)) !== $value) {
              throw new RuntimeException("igbinary 64-bit round trip failed");
          }
          if (!extension_loaded("imagick")) {
              throw new RuntimeException("imagick is not loaded");
          }
        '
      '';
    }))
  versions
