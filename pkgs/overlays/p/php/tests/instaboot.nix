{
  pkgs,
  preferredProfilePackages,
  testLib,
  ...
}: let
  versions = builtins.attrNames (import ../versions.nix);
  serverAttrs = pkgs.lib.concatMap (name: [name "${name}-int64"]) (builtins.filter (name: name != "php74") versions);

  mkInstabootTest = name: package: let
    php = package.shim;
  in
    testLib.mkScriptRun {
      name = "${name}-instaboot";
      packages = [testLib.wasmer php];
      timeout = 180;
      script = ''
        journal=$PWD/php.journal
        code='$token = bin2hex(random_bytes(16)); fwrite(STDOUT, "WARM:$token\n"); fflush(STDOUT); $line = fgets(STDIN); fwrite(STDOUT, "RESUMED:$token:" . trim($line) . "\n");'

        WASMER_FLAGS="--volume $PWD:$PWD --cwd $PWD --journal-writable $journal --snapshot-on first-stdin --stop-after-snapshot" \
          php -r "$code" >warm.out

        printf 'payload\n' | \
          WASMER_FLAGS="--volume $PWD:$PWD --cwd $PWD --journal $journal --skip-journal-stdio" \
          php -r "$code" >resumed.out

        warm=$(sed -n 's/^WARM:\([0-9a-f]\{32\}\)$/\1/p' warm.out)
        restoredWarm=$(sed -n 's/^WARM:\([0-9a-f]\{32\}\)$/\1/p' resumed.out)
        resumed=$(sed -n 's/^RESUMED:\([0-9a-f]\{32\}\):payload$/\1/p' resumed.out)
        test -s "$journal"
        test "$(wc -l <warm.out)" -eq 1
        test "$(wc -l <resumed.out)" -eq 2
        test -n "$warm"
        test "$warm" = "$restoredWarm"
        test "$warm" = "$resumed"
        echo "php instaboot ok"
      '';
    };

  mkServerInstabootTest = name: package: let
    php = package.shim;
  in
    testLib.mkScriptRun {
      name = "${name}-server-instaboot";
      packages = [pkgs.curl testLib.wasmer php];
      timeout = 180;
      script = ''
        journal=$PWD/php-server.journal
        mkdir docroot
        printf '%s\n' '<?php echo "restored server ok";' >docroot/index.php

        if ! timeout 30 env \
          WASMER_FLAGS="--net --volume $PWD:$PWD --cwd $PWD --journal-writable $journal --snapshot-on explicit --stop-after-snapshot" \
          php -S 127.0.0.1:8893 -t "$PWD/docroot" >snapshot.log 2>&1; then
          cat snapshot.log >&2
          exit 1
        fi
        if ! test -s "$journal"; then
          cat snapshot.log >&2
          exit 1
        fi
        wasmer journal compact "$journal" >journal-inspect.log

        WASMER_FLAGS="--net --volume $PWD:$PWD --cwd $PWD --journal $journal --skip-journal-stdio" \
          php -S 127.0.0.1:8893 -t "$PWD/docroot" >server.log 2>&1 &
        server_pid=$!
        trap 'kill $server_pid 2>/dev/null || true' EXIT

        response=
        for _ in $(seq 1 300); do
          kill -0 "$server_pid" 2>/dev/null || { cat journal-inspect.log server.log >&2; exit 1; }
          response=$(curl -fsS http://127.0.0.1:8893/index.php 2>/dev/null) || true
          [ "$response" = "restored server ok" ] && break
          sleep 0.1
        done
        if test "$response" != "restored server ok"; then
          cat journal-inspect.log server.log >&2
          exit 1
        fi
        echo "php server instaboot ok"
      '';
    };
in
  {
    php74-instaboot = mkInstabootTest "php74" preferredProfilePackages.php74;
    php74-int64-instaboot = mkInstabootTest "php74-int64" preferredProfilePackages."php74-int64";
  }
  // builtins.listToAttrs (map (name: {
      name = "${name}-server-instaboot";
      value = mkServerInstabootTest name preferredProfilePackages.${name};
    })
    serverAttrs)
