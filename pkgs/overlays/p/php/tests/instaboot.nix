{
  preferredProfilePackages,
  testLib,
  ...
}: let
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
in {
  php74-instaboot = mkInstabootTest "php74" preferredProfilePackages.php74;
  php74-int64-instaboot = mkInstabootTest "php74-int64" preferredProfilePackages."php74-int64";
}
