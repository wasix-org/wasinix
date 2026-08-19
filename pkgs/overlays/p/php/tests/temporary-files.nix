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
    pkgs.lib.nameValuePair "${attr}-temporary-files" (testLib.mkWasixRun {
      name = "${attr}-temporary-files";
      wasixPkgs = [wasmerPkgs.${attr}];
      script = ''
        php -r '
          $path = tempnam(sys_get_temp_dir(), "php-");
          if ($path === false || file_put_contents($path, "temporary") !== 9) {
            $errno = posix_get_last_error();
            throw new RuntimeException("tempnam failed: " . $errno . " " . posix_strerror($errno));
          }
          unlink($path);
          $stream = tmpfile();
          if ($stream === false || fwrite($stream, "temporary") !== 9) {
            throw new RuntimeException("tmpfile failed: " . json_encode(error_get_last()));
          }
          fclose($stream);
          echo "php temporary files ok\n";
        '
      '';
    }))
  versions
