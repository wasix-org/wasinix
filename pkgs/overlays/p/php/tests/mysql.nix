{
  crossPkgs,
  helpers,
  makeWasmerPackage,
  pkgs,
  testLib,
  ...
}: let
  attrs = builtins.attrNames (import ../versions.nix);
  wasmerPkgs = helpers.mkPhpShims "" {inherit crossPkgs makeWasmerPackage;};
in
  builtins.listToAttrs (pkgs.lib.imap0 (index: attr: let
      port = 9000 + index;
    in {
      name = "${attr}-mysql";
      value = testLib.mkWasixRun {
        name = "${attr}-mysql";
        nativePkgs = [pkgs.mariadb];
        wasixPkgs = [wasmerPkgs.${attr}];
        wasmerArgs = ["--net"];
        timeout = 900;
        script = ''
          mariadb-install-db \
            --datadir="$PWD/db" \
            --auth-root-authentication-method=normal \
            --skip-test-db >/dev/null
          mariadbd \
            --datadir="$PWD/db" \
            --socket="$PWD/mariadb.sock" \
            --bind-address=127.0.0.1 \
            --port=${toString port} \
            --skip-networking=0 >mariadb.log 2>&1 &
          mariadb_pid=$!
          trap 'kill "$mariadb_pid" 2>/dev/null || true; wait "$mariadb_pid" 2>/dev/null || true' EXIT

          for _ in $(seq 1 60); do
            mariadb-admin --host=127.0.0.1 --port=${toString port} --user=root ping >/dev/null 2>&1 && break
            sleep 1
          done
          mariadb-admin --host=127.0.0.1 --port=${toString port} --user=root ping

          cp ${./mysql.php} mysql.php
          php mysql.php ${toString port}
        '';
      };
    })
    attrs)
