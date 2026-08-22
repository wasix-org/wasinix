{
  entry,
  packages,
  pkgs,
  ...
}: {
  cargo-publish =
    pkgs.runCommandCC "wasinix-cargo-publish-check" {
      nativeBuildInputs = [
        entry.package.unwrapped
        packages.native.wasmer
        pkgs.python3
        pkgs.cargo
        pkgs.rustc
        pkgs.curl
        pkgs.gnutar
        pkgs.gzip
        pkgs.writableTmpDirAsHomeHook
      ];
      publisher = ../../../cargo-registry/publish-crate.py;
      server = packages.preferred.cargo-registry;
    } ''
      set -u
      port=8733
      base="http://127.0.0.1:$port"
      token=wasix_test
      export WASMER_DIR="$PWD/.wasmer"

      make_mint() {
        mkdir -p "$1/work/probe-0.1.0+wasix.1/src" "$1/crates"
        cat > "$1/work/probe-0.1.0+wasix.1/Cargo.toml" <<'EOF'
      [package]
      name = "probe"
      version = "0.1.0+wasix.1"
      edition = "2021"
      EOF
        printf 'pub fn ok() -> u32 { %s }\n' "$2" > "$1/work/probe-0.1.0+wasix.1/src/lib.rs"
        tar czf "$1/crates/probe-0.1.0+wasix.1.crate" -C "$1/work" "probe-0.1.0+wasix.1"
        rm -r "$1/work"
        cp "$publisher" "$1/publish-crate.py"
        cat > "$1/manifest.json" <<'EOF'
      {"crates":[{"crate":"probe","wasixVersion":"0.1.0+wasix.1","crateFile":"probe-0.1.0+wasix.1.crate","upstream":"0.1.0","rel":1}],"shadowLimits":[],"excluded":[],"unpinned":[],"stray":[]}
      EOF
      }
      make_mint mint1 42
      make_mint mint2 43

      mkdir -p data
      wasmer run "$server/bin/wasix-cargo-registry.wasm" \
        --net --enable-threads \
        --volume "$PWD/data:/data" \
        --env "REGISTRY_LISTEN_ADDR=0.0.0.0:$port" \
        --env "REGISTRY_BASE_URL=$base" \
        --env "REGISTRY_AUTH_TOKEN_HASHES=$(printf %s "$token" | sha256sum | cut -d' ' -f1)" \
        --env "REGISTRY_STORAGE_PATH=/data" &
      server_pid=$!
      trap 'kill $server_pid 2>/dev/null || true' EXIT
      for _ in $(seq 1 150); do
        kill -0 $server_pid 2>/dev/null || { echo "server exited early" >&2; exit 1; }
        curl -fsS "$base/config.json" >/dev/null 2>&1 && break
        sleep 0.2
      done
      curl -fsS "$base/config.json" >/dev/null

      wasinix cargo publish --mint mint1 --registry "$base" --dry-run
      if curl -fsS "$base/pr/ob/probe" 2>/dev/null | grep -q '"vers"'; then
        echo "dry run published" >&2
        exit 1
      fi

      WASIX_CARGO_TOKEN=$token wasinix cargo publish --mint mint1 --registry "$base"
      curl -fsS "$base/pr/ob/probe" | grep -q '"vers":"0.1.0+wasix.1"'

      wasinix cargo publish --mint mint1 --registry "$base" --json > again.json
      python3 - <<'PY'
      import json
      report = json.load(open("again.json"))
      [outcome] = report["outcomes"]
      assert outcome["action"] == "skip", outcome
      assert not outcome["published"], outcome
      PY

      for extra in "" "--dry-run"; do
        if WASIX_CARGO_TOKEN=$token wasinix cargo publish --mint mint2 \
            --registry "$base" $extra > conflict.txt; then
          echo "conflicting publish succeeded" >&2
          exit 1
        fi
        grep -q 'versions bump artifacts.registry.cargo-registry.crates.probe@0.1.0' conflict.txt
      done

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
      ( cd app && CARGO_HOME="$PWD/../cargo-home" cargo run --quiet )
      touch "$out"
    '';
}
