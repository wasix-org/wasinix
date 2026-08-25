{
  artifacts,
  entry,
  packages,
  pkgs,
  ...
}: {
  serve-all =
    pkgs.runCommand "wasinix-serve-all-check" {
      nativeBuildInputs = [
        entry.package.unwrapped
        packages.native.wasmer
        pkgs.python3
        pkgs.curl
        pkgs.gnutar
        pkgs.gzip
        pkgs.writableTmpDirAsHomeHook
      ];
      server = packages.preferred.cargo-registry;
      bashWebc = artifacts.webc.bash;
    } ''
      export WASMER_DIR="$PWD/.wasmer"
      mkdir -p mint/work/probe-0.1.0+wasix.1/src mint/crates index/simple
      cat > mint/work/probe-0.1.0+wasix.1/Cargo.toml <<'EOF'
      [package]
      name = "probe"
      version = "0.1.0+wasix.1"
      edition = "2021"
      EOF
      echo 'pub fn ok() {}' > mint/work/probe-0.1.0+wasix.1/src/lib.rs
      tar czf mint/crates/probe-0.1.0+wasix.1.crate -C mint/work probe-0.1.0+wasix.1
      rm -r mint/work
      cat > mint/manifest.json <<'EOF'
      {"crates":[{"crate":"probe","wasixVersion":"0.1.0+wasix.1","crateFile":"probe-0.1.0+wasix.1.crate","upstream":"0.1.0","rel":1}],"shadowLimits":[],"excluded":[],"unpinned":[],"stray":[]}
      EOF
      echo '<html></html>' > index/simple/index.html
      wasinix serve --mint mint --index index --server "$server" --webc "$bashWebc" -- sh -c '
        set -eu
        curl -fsS http://127.0.0.1:8319/config.json >/dev/null
        curl -fsS http://127.0.0.1:8318/simple/ >/dev/null
        case "$WASMER_FLAGS" in *--include-webc*) : ;; *) echo "no webc tree in WASMER_FLAGS" >&2; exit 1 ;; esac
      '
      touch "$out"
    '';
}
