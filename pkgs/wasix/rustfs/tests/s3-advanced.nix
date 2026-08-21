# Harder S3 e2e tests against `rustfs server` under wasmer, driven by the minio
# client over the --net loopback bridge. Each pushes a path the 29-byte
# round-trip (s3-roundtrip.nix) does not: real multipart, listing + nested
# prefixes, concurrent writes (stresses the reactor/futex fixes), and re-reading
# a data dir across a server restart.
{
  pkgs,
  entry,
  harnesses,
  ...
}: let
  # Boot rustfs + wait until the S3 endpoint answers; `mc alias set` pings it, so
  # a successful alias doubles as readiness. stop_server waits for full exit so
  # the next start_server can rebind the port (used by the restart test).
  preamble = ''
    export MC_CONFIG_DIR="$PWD/.mc"
    export RUST_BACKTRACE=1
    export RUSTFS_CONSOLE_ENABLE=false
    mkdir -p data
    # -E so the trap also fires for failures inside functions/subshells; the
    # script runs under `set -e`, so without a trap an unguarded `mc` failure
    # would abort with no server-side context.
    set -E
    trap 'rc=$?; trap - ERR; echo "--- server.log (last 40) ---"; tail -40 server.log 2>/dev/null; exit $rc' ERR
    start_server() {
      ( rustfs server ./data --address 127.0.0.1:9000 >>server.log 2>&1 & echo $! >server.pid )
      for _i in $(seq 1 180); do
        sleep 1
        mc -q alias set local http://127.0.0.1:9000 rustfsadmin rustfsadmin >/dev/null 2>&1 && return 0
        kill -0 "$(cat server.pid)" 2>/dev/null || { echo "server died during startup"; tail -30 server.log; return 1; }
      done
      echo "server never came up in 180s"; tail -30 server.log; return 1
    }
    stop_server() {
      pid=$(cat server.pid 2>/dev/null) || return 0
      kill "$pid" 2>/dev/null || true
      for _ in $(seq 1 40); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
      kill -9 "$pid" 2>/dev/null || true
    }
  '';
  mkTest = name: body:
    harnesses.hostShell {
      inherit name;
      wasixCommands = builtins.attrValues entry.commands;
      hostPackages = [pkgs.minio-client pkgs.coreutils pkgs.gnugrep pkgs.diffutils];
      wasmerArgs = ["--net"];
      forwardEnv = harnesses.defaultForwardEnv ++ ["RUST_BACKTRACE" "RUSTFS_CONSOLE_ENABLE"];
      script = preamble + "\n" + body;
    };
in {
  # 24 MiB in 5 MiB parts: exercises CreateMultipartUpload / UploadPart x5 /
  # CompleteMultipartUpload, streaming erasure write, and the fsync-per-part
  # durability path. Verify byte-exact via sha256.
  #
  # --part-size is set explicitly rather than leaning on mc's 16 MiB default: at
  # the default a change on either side (mc's default, or the object size here)
  # could drop this to a single PutObject and the test would still pass while
  # silently no longer covering UploadPart at all. 5 MiB is the S3 minimum, so
  # the split is guaranteed for any object over that.
  s3-multipart-large = mkTest "rustfs-s3-multipart-large" ''
    start_server || exit 1
    head -c 25165824 /dev/urandom > big.bin
    sha_in=$(sha256sum big.bin | cut -d' ' -f1)
    mc -q mb local/bigbucket
    mc -q put --part-size 5MiB big.bin local/bigbucket/big.bin
    mc -q cp local/bigbucket/big.bin got.bin
    sha_out=$(sha256sum got.bin | cut -d' ' -f1)
    stop_server
    if [ "$sha_in" = "$sha_out" ]; then
      echo "PASS: 24MiB multipart round-trip byte-exact ($sha_in)"
    else
      echo "FAIL: sha mismatch in=$sha_in out=$sha_out"; ls -l big.bin got.bin; exit 1
    fi
  '';

  # CRUD + listing: nested-prefix keys (deep path creation on wasix), recursive
  # list count, overwrite, binary integrity, delete -> 404.
  s3-crud-list = mkTest "rustfs-s3-crud-list" ''
    start_server || exit 1
    fail=0
    mc -q mb local/data
    for k in a/b/c/deep.txt x/y.txt top.txt logs/2026/07/app.log; do
      printf 'content-of-%s' "$k" | mc -q pipe "local/data/$k"
    done
    n=$(mc -q ls --recursive local/data | grep -c . || true)
    [ "$n" -eq 4 ] || { echo "FAIL: expected 4 objects, listed $n"; mc -q ls --recursive local/data; fail=1; }
    got=$(mc -q cat local/data/a/b/c/deep.txt || true)
    [ "$got" = "content-of-a/b/c/deep.txt" ] || { echo "FAIL: nested get: '$got'"; fail=1; }
    printf 'v2' | mc -q pipe local/data/top.txt
    got=$(mc -q cat local/data/top.txt || true)
    [ "$got" = "v2" ] || { echo "FAIL: overwrite: '$got'"; fail=1; }
    head -c 4096 /dev/urandom > rnd.bin
    mc -q cp rnd.bin local/data/rnd.bin
    mc -q cp local/data/rnd.bin rnd.out
    cmp rnd.bin rnd.out || { echo "FAIL: binary mismatch"; fail=1; }
    mc -q rm local/data/top.txt
    if mc -q stat local/data/top.txt >/dev/null 2>&1; then echo "FAIL: object present after rm"; fail=1; fi
    stop_server
    [ "$fail" -eq 0 ] && echo "PASS: crud + list + nested-prefix + binary + overwrite + delete" || exit 1
  '';

  # 12 concurrent PUTs from independent mc processes: stresses cross-thread task
  # wakeup (the futex_wake fix) and the reactor Waker under real load.
  s3-concurrent = mkTest "rustfs-s3-concurrent" ''
    start_server || exit 1
    mc -q mb local/concbucket
    pids=""
    for i in $(seq 1 12); do
      ( printf 'payload-%s' "$i" | mc -q pipe "local/concbucket/obj-$i.txt" ) &
      pids="$pids $!"
    done
    rc=0
    for p in $pids; do wait "$p" || rc=1; done
    fail=0
    for i in $(seq 1 12); do
      got=$(mc -q cat "local/concbucket/obj-$i.txt" 2>/dev/null || true)
      [ "$got" = "payload-$i" ] || { echo "FAIL: obj-$i = '$got'"; fail=1; }
    done
    n=$(mc -q ls local/concbucket | grep -c . || true)
    [ "$n" -eq 12 ] || { echo "FAIL: expected 12 objects, listed $n"; fail=1; }
    stop_server
    [ "$fail" -eq 0 ] && [ "$rc" -eq 0 ] && echo "PASS: 12 concurrent puts round-tripped" || exit 1
  '';

  # Objects written before a kill must re-read after a restart on the same data
  # dir: covers the on-disk xl layout being re-openable, erasure metadata being
  # recovered on boot, and reads not depending on in-memory state from the write.
  #
  # This is deliberately not a durability test. Both runs share a host page cache
  # (the data dir is a --volume mapping), so a write that never reached the
  # platter still reads back and this would pass with fsync stubbed out. Proving
  # the fd_datasync fix needs the write path to return at all, which is what
  # s3-roundtrip.nix covers: without it PutObject 500s on EACCES.
  s3-restart-persistence = mkTest "rustfs-s3-restart-persistence" ''
    start_server || exit 1
    mc -q mb local/persist
    payload="survives-a-restart"
    printf '%s' "$payload" | mc -q pipe local/persist/keep.txt
    head -c 8192 /dev/urandom > blob.bin
    mc -q cp blob.bin local/persist/blob.bin
    stop_server
    echo "--- restarting server on the same data dir ---"
    start_server || exit 1
    got=$(mc -q cat local/persist/keep.txt 2>/dev/null || true)
    mc -q cp local/persist/blob.bin blob.out 2>/dev/null || true
    stop_server
    fail=0
    [ "$got" = "$payload" ] || { echo "FAIL: text object not re-read after restart: '$got'"; fail=1; }
    cmp blob.bin blob.out 2>/dev/null || { echo "FAIL: binary object not re-read after restart"; fail=1; }
    [ "$fail" -eq 0 ] && echo "PASS: objects re-read after a server restart" || exit 1
  '';
}
