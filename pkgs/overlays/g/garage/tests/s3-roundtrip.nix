# End-to-end S3 test: boot a single-node garage cluster under wasmer, drive its
# own CLI over the RPC socket to lay out the node and mint a key, then run a
# make-bucket / put / get round-trip with the minio client (`mc`) over the
# wasmer --net loopback bridge.
#
# The CLI half exercises the RPC stack (netapp over tokio/mio, sodiumoxide
# handshake, sqlite metadata store) and the S3 half the HTTP listener, SigV4
# auth, and block read/write through the data dir.
{
  pkgs,
  entry,
  harnesses,
  ...
}: {
  s3-roundtrip = harnesses.hostShell {
    name = "garage-s3-roundtrip";
    wasixCommands = builtins.attrValues entry.commands;
    hostPackages = [pkgs.minio-client pkgs.coreutils];
    wasmerArgs = ["--net"];
    forwardEnv = harnesses.defaultForwardEnv ++ ["RUST_BACKTRACE" "GARAGE_CONFIG_FILE"];
    script = ''
      export RUST_BACKTRACE=1
      export GARAGE_CONFIG_FILE="$PWD/garage.toml"
      export MC_CONFIG_DIR="$PWD/.mc"
      mkdir -p meta data

      cat >garage.toml <<EOF
      metadata_dir = "$PWD/meta"
      data_dir = "$PWD/data"
      db_engine = "sqlite"
      replication_factor = 1
      rpc_bind_addr = "127.0.0.1:3901"
      rpc_public_addr = "127.0.0.1:3901"
      rpc_secret = "6161616161616161616161616161616161616161616161616161616161616161"

      [s3_api]
      s3_region = "garage"
      api_bind_addr = "127.0.0.1:3900"
      root_domain = ".s3.garage.localhost"
      EOF

      # -E so the trap also fires for failures inside functions/subshells; the
      # script runs under `set -e`, so without a trap an unguarded failure would
      # abort with no server-side context.
      set -E
      trap 'rc=$?; trap - ERR; echo "--- server.log (last 40) ---"; tail -40 server.log 2>/dev/null || true; exit $rc' ERR

      ( garage server >server.log 2>&1 & echo $! >server.pid )

      up=""
      for i in $(seq 1 180); do
        sleep 1
        if garage status >/dev/null 2>&1; then up=1; break; fi
        kill -0 "$(cat server.pid)" 2>/dev/null || { echo "FAIL: server exited during startup"; tail -40 server.log; exit 1; }
      done
      [ -n "$up" ] || { echo "FAIL: RPC never came up in 180s"; tail -40 server.log; exit 1; }
      echo "node ready after ''${i}s"

      node=$(garage node id -q | cut -d@ -f1)
      garage layout assign "$node" -z dc1 -c 1G
      garage layout apply --version 1

      garage bucket create probe-bucket
      garage key create probe-key >key.txt
      garage bucket allow --read --write --key probe-key probe-bucket

      key_id=$(sed -n 's/^Key ID: //p' key.txt)
      secret=$(sed -n 's/^Secret key: //p' key.txt)
      [ -n "$key_id" ] && [ -n "$secret" ] || { echo "FAIL: could not read the minted key"; cat key.txt; exit 1; }

      mc alias set local http://127.0.0.1:3900 "$key_id" "$secret"

      payload="hello from wasix under wasmer"
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
