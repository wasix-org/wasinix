# End-to-end S3 test: boot `rustfs server` under wasmer, then drive a real
# make-bucket / put / get round-trip with the minio client (`mc`) over the
# wasmer --net loopback bridge. Exercises the whole stack: erasure storage init,
# the tokio/mio reactor (needs the wasmer futex_wake fix + the tokio wasi Waker),
# the HTTP listener, SigV4 auth, and object read/write.
#
# This is also the test that guards the fd_datasync/fd_sync rights fix: rustfs
# fsyncs object writes for durability, and without the patch that EACCES surfaces
# as a 500 InternalError on PutObject, so `mc pipe` fails outright. The data dir
# is a --volume host mapping, which is exactly the case where path_open's rights
# delegation masks the implied sync rights.
{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: {
  s3-roundtrip = testLib.mkWasixRun {
    name = "rustfs-s3-roundtrip";
    wasixPkgs = [wasmerPkgs.rustfs];
    nativePkgs = [pkgs.minio-client pkgs.coreutils];
    wasmerArgs = ["--net"];
    forwardEnv = testLib.defaultForwardEnv ++ ["RUST_BACKTRACE" "RUSTFS_CONSOLE_ENABLE"];
    script = ''
      export RUST_BACKTRACE=1
      export RUSTFS_CONSOLE_ENABLE=false
      export MC_CONFIG_DIR="$PWD/.mc"
      mkdir -p data
      # -E so the trap also fires for failures inside functions/subshells; the
      # script runs under `set -e`, so without a trap an unguarded `mc` failure
      # would abort with no server-side context.
      set -E
      trap 'rc=$?; trap - ERR; echo "--- server.log (last 40) ---"; tail -40 server.log 2>/dev/null || true; exit $rc' ERR

      ( rustfs server ./data --address 127.0.0.1:9000 >server.log 2>&1 & echo $! >server.pid )

      # Storage init + listener take a while under wasmer; `mc alias set` pings the
      # endpoint, so a successful alias doubles as the readiness probe.
      up=""
      for i in $(seq 1 180); do
        sleep 1
        if mc alias set local http://127.0.0.1:9000 rustfsadmin rustfsadmin >/dev/null 2>&1; then up=1; break; fi
        kill -0 "$(cat server.pid)" 2>/dev/null || { echo "FAIL: server exited during startup"; tail -40 server.log; exit 1; }
      done
      [ -n "$up" ] || { echo "FAIL: S3 endpoint never came up in 180s"; tail -40 server.log; exit 1; }
      echo "server ready after ''${i}s"

      payload="hello from wasix under wasmer"
      mc mb local/probe-bucket
      printf '%s' "$payload" | mc pipe local/probe-bucket/greeting.txt
      got=$(mc cat local/probe-bucket/greeting.txt || true)

      kill "$(cat server.pid)" 2>/dev/null || true

      if [ "$got" = "$payload" ]; then
        echo "PASS: S3 put/get round-trip matched"
      else
        echo "FAIL: round-trip mismatch"
        echo "  wrote: $payload"
        echo "  read:  $got"
        tail -40 server.log
        exit 1
      fi
    '';
  };
}
