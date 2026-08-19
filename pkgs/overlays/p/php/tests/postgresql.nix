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
      port = 8900 + index;
    in {
      name = "${attr}-postgresql";
      value = testLib.mkWasixRun {
        name = "${attr}-postgresql";
        nativePkgs = [pkgs.postgresql];
        wasixPkgs = [wasmerPkgs.${attr}];
        wasmerArgs = ["--net"];
        timeout = 900;
        script = ''
          initdb -D db -U postgres --no-locale --encoding=UTF8 >/dev/null
          postgres -D db -k "$PWD" -h 127.0.0.1 -p ${toString port} >postgres.log 2>&1 &
          postgres_pid=$!
          trap 'kill "$postgres_pid" 2>/dev/null || true; wait "$postgres_pid" 2>/dev/null || true' EXIT

          for _ in $(seq 1 60); do
            pg_isready -h 127.0.0.1 -p ${toString port} -U postgres >/dev/null 2>&1 && break
            sleep 1
          done
          pg_isready -h 127.0.0.1 -p ${toString port} -U postgres

          cp ${./postgresql.php} postgresql.php
          php postgresql.php ${toString port}
        '';
      };
    })
    attrs)
