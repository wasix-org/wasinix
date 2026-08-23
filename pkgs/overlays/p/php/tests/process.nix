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
    pkgs.lib.nameValuePair "${attr}-process" (testLib.mkWasixRun {
      name = "${attr}-process";
      wasixPkgs = [wasmerPkgs.${attr}];
      broken =
        if attr == "php74"
        then "the off-profile runtime reports a spawned guest's exit status as 45"
        else null;
      script = ''
        php -r '
          $descriptors = [
            ["pipe", "r"],
            ["pipe", "w"],
            ["pipe", "w"]
          ];
          $process = proc_open(
            ["php", "-r", "fwrite(STDOUT, strtoupper(stream_get_contents(STDIN))); fwrite(STDERR, getenv(\"PHP_CHILD\")); exit(7);"],
            $descriptors,
            $pipes,
            null,
            ["PHP_CHILD" => "child-stderr"]
          );
          if (!is_resource($process)) {
            throw new RuntimeException("proc_open failed");
          }
          fwrite($pipes[0], "child-stdin");
          fclose($pipes[0]);
          $stdout = stream_get_contents($pipes[1]);
          $stderr = stream_get_contents($pipes[2]);
          fclose($pipes[1]);
          fclose($pipes[2]);
          $status = proc_close($process);
          if ($stdout !== "CHILD-STDIN" || $stderr !== "child-stderr" || $status !== 7) {
            throw new RuntimeException(json_encode([$stdout, $stderr, $status]));
          }
          echo "php process ok\n";
        '
      '';
    }))
  versions
