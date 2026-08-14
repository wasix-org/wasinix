# Minimal reproducer for the signed wide-multiply overflow miscompile seen in
# NumPy, pandas, and fastavro.
{
  stdenvNoCC,
  wasixcc,
  wasixRun,
  toolchain,
}: let
  program = stdenvNoCC.mkDerivation {
    name = "wasix-wide-arithmetic-repro-program";
    dontUnpack = true;

    nativeBuildInputs = [wasixcc];

    buildPhase = ''
      runHook preBuild
      ${toolchain.commonPreConfigure}
      export WASIXCC_COMPILER_POST_FLAGS=-fno-PIC:-mwide-arithmetic
      wasixcc -O3 ${./wide-arithmetic-repro.c} -o repro.wasm
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp repro.wasm "$out/"
      runHook postInstall
    '';
  };
in
  stdenvNoCC.mkDerivation {
    name = "wasix-wide-arithmetic-repro";
    dontUnpack = true;
    nativeBuildInputs = [wasixRun.run];

    buildPhase = ''
      runHook preBuild
      wasix-run ${program}/repro.wasm 2>&1 | tee repro.log || true
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp repro.log "$out"
      runHook postInstall
    '';

    passthru = {inherit program;};
  }
