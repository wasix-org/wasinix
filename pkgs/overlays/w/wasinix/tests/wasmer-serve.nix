{
  artifacts,
  entry,
  packages,
  pkgs,
  ...
}: {
  wasmer-serve =
    pkgs.runCommand "wasinix-wasmer-serve-check" {
      nativeBuildInputs = [entry.package.unwrapped packages.native.wasmer pkgs.writableTmpDirAsHomeHook];
      bashWebc = artifacts.webc.bash;
      bashDeps = artifacts.pkg.bash.depTree;
    } ''
      export WASMER_DIR="$PWD/.wasmer"
      wasinix wasmer serve --webc "$bashWebc" --webc "$bashDeps" --out tree -- sh -c '
        set -eu
        file=$(ls tree/wasmer/bash)
        ref="wasmer/bash@''${file%.webc}"
        out=$(wasmer run $WASMER_FLAGS "$ref" -- -c "echo served-offline")
        [ "$out" = served-offline ]
      '
      touch "$out"
    '';
}
