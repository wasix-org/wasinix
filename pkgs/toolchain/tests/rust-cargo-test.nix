# `cargo test` through the wasix toolchain, build-once / run-many: a
# wasmer-free testBuild compiles the test binary (--no-run) and translates its
# legacy Wasm-EH to exnref, a pass cargo-wasix only applies when it runs a
# binary; a run-only derivation execs the stash under wasix-run, so a wasmer
# bump moves only the run.
{
  lib,
  runCommand,
  writeText,
  rustPlatform,
  # { stub, run }; run carries the runtime
  wasixRun,
  # for the legacy-EH -> exnref translation --no-run leaves undone
  binaryen,
}: let
  cargoToml = writeText "Cargo.toml" ''
    [package]
    name = "wasix-cargo-test"
    version = "0.0.0"
    edition = "2021"

    [lib]
    name = "wasix_cargo_test"
    path = "src/lib.rs"
  '';
  cargoLockText = ''
    version = 3

    [[package]]
    name = "wasix-cargo-test"
    version = "0.0.0"
  '';
  cargoLockFile = writeText "Cargo.lock" cargoLockText;
  # env::consts::OS is "" on the wasm32-wasmer-wasi fork target, so the proof is
  # a forwarded env var, not the platform string: it reaches the test only by
  # going through wasix-run and the runtime. WASIX_RUN_ENV below adds it to
  # wasix-run's forward allowlist.
  proof = "handoff-ok";
  libRs = writeText "lib.rs" ''
    #[cfg(test)]
    mod tests {
        #[test]
        fn runs_under_wasmer_with_forwarded_env() {
            let got = std::env::var("WASIX_CARGO_PROOF").unwrap_or_default();
            println!("WASIX_CARGO_TEST_MARKER arch={} proof={}",
                     std::env::consts::ARCH, got);
            assert_eq!(got, "${proof}",
                       "forwarded env not seen: the runner/runtime didn't execute the test");
        }
    }
  '';
  src = runCommand "wasix-cargo-test-src" {} ''
    mkdir -p "$out/src"
    cp ${cargoToml} "$out/Cargo.toml"
    cp ${cargoLockFile} "$out/Cargo.lock"
    cp ${libRs} "$out/src/lib.rs"
  '';

  # wasmer-free: build the test binary, translate it to exnref, stash it.
  testBuild = rustPlatform.buildRustPackage {
    pname = "wasix-cargo-test-tree";
    version = "0.0.0";
    inherit src;
    cargoLock.lockFileContents = cargoLockText;

    # doCheck builds the test binary; the cross gate is force-zeroed by nixpkgs
    # (canExecuteHostOnBuild), so re-export it before the phase list, as
    # emulated-check.nix does. --no-run compiles without executing (no wasmer).
    doCheck = true;
    prePhases = ["wasixEnableCheck"];
    wasixEnableCheck = "export doCheck=1";
    cargoTestFlags = ["--no-run"];

    # wasm-opt uses the same pass + feature set as set/rust-platform.nix's .so
    # translation; keep the two in step.
    installPhase = ''
      mkdir -p "$out/bin"
      shopt -s nullglob
      found=0
      for w in target/wasm32-wasmer-wasi/release/deps/*.wasm; do
        base=$(basename "$w")
        ${binaryen}/bin/wasm-opt "$w" \
          --enable-bulk-memory --enable-threads --enable-reference-types \
          --enable-exception-handling --no-validation --translate-to-exnref \
          -o "$out/bin/$base"
        echo "$base" >> "$out/manifest"
        found=1
      done
      [ "$found" = 1 ] || {
        echo "no test binary built under target/.../deps" >&2
        exit 1
      }
    '';

    meta.description = "wasix cargo-test binary, built + exnref-translated, for the run-only handoff check";
  };
in
  runCommand "wasix-cargo-test" {
    nativeBuildInputs = [wasixRun.run];
  } ''
    export HOME="$NIX_BUILD_TOP/home"
    mkdir -p "$HOME"
    export WASIX_CARGO_PROOF=${proof}
    export WASIX_RUN_ENV=WASIX_CARGO_PROOF

    fail=0
    while read -r base; do
      echo "running $base under wasmer"
      log="$NIX_BUILD_TOP/$base.log"
      if wasix-run "${testBuild}/bin/$base" --nocapture >"$log" 2>&1; then :; else
        echo "FAIL: $base exited nonzero" >&2
        fail=1
      fi
      cat "$log"
      grep -q "WASIX_CARGO_TEST_MARKER arch=wasm32 proof=${proof}" "$log" || {
        echo "FAIL: proof marker missing from $base (did it really run under the runtime?)" >&2
        fail=1
      }
    done < "${testBuild}/manifest"

    [ "$fail" -eq 0 ] || exit 1
    mkdir -p "$out"
    echo "cargo test ran under wasmer (run-only, from a wasmer-free stash)" > "$out/result"
  ''
