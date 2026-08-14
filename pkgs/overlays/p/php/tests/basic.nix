{
  pkgs,
  testLib,
  wasmerPkgs,
  ...
}: let
  versions = {
    php74 = "7.4";
    php81 = "8.1";
    php82 = "8.2";
    php83 = "8.3";
    php84 = "8.4";
    php85 = "8.5";
  };
in
  pkgs.lib.mapAttrs' (attr: expected:
    pkgs.lib.nameValuePair "${attr}-basic" (testLib.mkWasixRun {
      name = "${attr}-basic";
      wasixPkgs = [wasmerPkgs.${attr}];
      script = ''
        version=$(php -r 'echo PHP_MAJOR_VERSION, ".", PHP_MINOR_VERSION;')
        test "$version" = ${pkgs.lib.escapeShellArg expected}

        php -r '
          $required = [
            "curl", "gd", "igbinary", "imagick", "intl", "json",
            "mysqli", "openssl", "pdo_pgsql", "pdo_sqlite", "pgsql", "phar",
            "sodium", "tidy", "zip"
          ];
          $missing = array_values(array_filter(
            $required,
            static function ($extension) { return !extension_loaded($extension); }
          ));
          if ($missing) {
            fwrite(STDERR, "missing extensions: " . implode(", ", $missing) . "\n");
            exit(1);
          }
          preg_match("/w(as)ix/", "wasix", $matches);
          echo json_encode(["sum" => array_sum([1, 2, 3]), "match" => $matches[1]]), "\n";
        ' | grep -Fx '{"sum":6,"match":"as"}'
      '';
    }))
  versions
