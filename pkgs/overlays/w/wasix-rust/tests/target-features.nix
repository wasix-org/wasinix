# The wasm feature baseline for the WASIX rust targets. It is declared in the
# target spec, so it reaches every rustc invocation instead of only the ones
# cargo-wasix gets to set RUSTFLAGS for.
{
  entry,
  pkgs,
  ...
}: let
  inherit (pkgs) lib;
  features = [
    "atomics"
    "bulk-memory"
    "mutable-globals"
    "sign-ext"
    "nontrapping-fptoint"
    "simd128"
    "relaxed-simd"
    "extended-const"
    "wide-arithmetic"
  ];
  targets = [
    "wasm32-wasmer-wasi"
    "wasm32-wasmer-wasi-dl"
  ];
in {
  target-features = pkgs.runCommand "wasix-rust-target-features" {} ''
    fail=0
    for target in ${lib.escapeShellArgs targets}; do
      cfg=$(${lib.getExe' entry.package "rustc"} --print cfg --target "$target")
      for feature in ${lib.escapeShellArgs features}; do
        grep -qxF "target_feature=\"$feature\"" <<<"$cfg" || {
          echo "FAIL: $target does not enable $feature" >&2
          fail=1
        }
      done
    done

    [ "$fail" -eq 0 ] || exit 1
    mkdir -p "$out"
    echo "wasm feature baseline present on the wasix rust targets" > "$out/result"
  '';
}
