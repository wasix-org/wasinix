# End to end: run the cross-built wasm server under wasmer (as on Edge), publish
# a crate through its real API, and have native cargo resolve and compile it from
# the server's sparse index over loopback HTTP. Fabricates its own one-crate
# payload rather than depending on the mint. Same --net + loopback as the git tests.
{
  pkgs,
  testLib,
  wasmerPkgs,
}: {
  serve = testLib.mkWasixRun {
    name = "cargo-registry-serve";
    nativePkgs = [pkgs.cargo pkgs.rustc pkgs.stdenv.cc pkgs.python3 pkgs.curl pkgs.coreutils pkgs.gnutar pkgs.gzip];
    wasixPkgs = [wasmerPkgs.wasix-cargo-registry];
    wasmerArgs = ["--net" "--enable-threads"];
    # The server reads its config from these; forward them into the guest.
    forwardEnv =
      testLib.defaultForwardEnv
      ++ ["REGISTRY_LISTEN_ADDR" "REGISTRY_BASE_URL" "REGISTRY_AUTH_TOKEN_HASHES" "REGISTRY_STORAGE_PATH"];
    script = ''
      port=8731
      base="http://127.0.0.1:$port"
      token=wasix_test
      export REGISTRY_LISTEN_ADDR="0.0.0.0:$port"
      export REGISTRY_BASE_URL="$base"
      export REGISTRY_AUTH_TOKEN_HASHES="$(printf %s "$token" | sha256sum | cut -d' ' -f1)"
      # Under $WASIX_TEST_ROOT, already --volume'd, so the server keeps fsync
      # rights on its storage.
      mkdir -p "$WASIX_TEST_ROOT/data"
      export REGISTRY_STORAGE_PATH="$WASIX_TEST_ROOT/data"

      wasix-cargo-registry &
      server_pid=$!
      trap 'kill $server_pid 2>/dev/null || true' EXIT

      for _ in $(seq 1 150); do
        kill -0 $server_pid 2>/dev/null || { echo "cargo-registry: server exited early" >&2; exit 1; }
        curl -fsS "$base/config.json" >/dev/null 2>&1 && break
        sleep 0.2
      done
      curl -fsS "$base/config.json" >/dev/null \
        || { echo "cargo-registry: server never became ready" >&2; exit 1; }

      # Zero-dep so it resolves without crates.io. The overlay only accepts
      # +wasix.N versions, and a plain `probe = "0.1.0"` still resolves to one
      # (semver ignores build metadata, the property the overlay leans on).
      mkdir -p "probe-0.1.0+wasix.1/src"
      cat > "probe-0.1.0+wasix.1/Cargo.toml" <<'EOF'
      [package]
      name = "probe"
      version = "0.1.0+wasix.1"
      edition = "2021"
      EOF
      echo 'pub fn ok() -> u32 { 42 }' > "probe-0.1.0+wasix.1/src/lib.rs"
      tar czf "probe-0.1.0+wasix.1.crate" "probe-0.1.0+wasix.1"

      # Cargo's publish wire format: <u32 len><json meta><u32 len><.crate>.
      # Inlined since a zero-dependency crate's publish metadata is trivial.
      python3 - "$base" "$token" "probe-0.1.0+wasix.1.crate" <<'PY'
      import json, pathlib, struct, sys, urllib.request
      base, token, crate = sys.argv[1], sys.argv[2], sys.argv[3]
      meta = json.dumps(
          {"name": "probe", "vers": "0.1.0+wasix.1", "deps": [], "features": {}, "links": None, "rust_version": None}
      ).encode()
      tarball = pathlib.Path(crate).read_bytes()
      body = struct.pack("<I", len(meta)) + meta + struct.pack("<I", len(tarball)) + tarball
      req = urllib.request.Request(
          f"{base}/api/v1/crates/new", data=body, method="PUT", headers={"Authorization": token}
      )
      try:
          with urllib.request.urlopen(req) as resp:
              assert resp.status == 200, resp.status
      except urllib.error.HTTPError as err:
          sys.exit(f"publish rejected: {err.code} {err.read().decode(errors='replace')}")
      PY

      mkdir -p app/src app/.cargo
      cat > app/Cargo.toml <<'EOF'
      [package]
      name = "consume"
      version = "0.0.0"
      edition = "2021"
      [dependencies]
      probe = "0.1.0"
      EOF
      cat > app/.cargo/config.toml <<EOF
      [source.crates-io]
      replace-with = "wasix"
      [source.wasix]
      registry = "sparse+$base/"
      EOF
      echo 'fn main() { assert_eq!(probe::ok(), 42); }' > app/src/main.rs

      ( cd app && CARGO_HOME="$WASIX_TEST_ROOT/cargo-home" cargo build )

      got=$(sed -n '/name = "probe"/,/^$/p' app/Cargo.lock | sed -n 's/^version = "\(.*\)"/\1/p')
      [ "$got" = "0.1.0+wasix.1" ] \
        || { echo "cargo-registry: resolved probe $got, expected 0.1.0+wasix.1" >&2; exit 1; }
      echo "ok: wasm server served probe $got over $base and cargo compiled it"
    '';
  };
}
