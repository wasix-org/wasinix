# Cross-build a C program against the wasix reference LAPACK/BLAS via pkg-config,
# the same discovery path scipy uses, and run it under wasmer. lapack-reference is
# PIC-only, hence crossPkgsPic.
{
  testLib,
  crossPkgsPic,
  makeWasmerPackage,
  ...
}: let
  crossPkgs = crossPkgsPic;
  prog = crossPkgs.stdenv.mkDerivation {
    pname = "lapack-smoke";
    version = "1.0.0";
    dontUnpack = true;
    nativeBuildInputs = [crossPkgs.pkg-config];
    buildInputs = [crossPkgs.lapack-reference];
    # Cross pkg-config is the target-prefixed wrapper in $PKG_CONFIG; bare
    # `pkg-config` is not on PATH.
    buildPhase = ''
      runHook preBuild
      $CC ${./smoke.c} -o lapack-smoke.wasm $("$PKG_CONFIG" --cflags --libs --static lapack cblas)
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 lapack-smoke.wasm -t "$out/bin"
      runHook postInstall
    '';
    passthru.wasmer.name = "lapack-smoke";
  };
in {
  smoke = testLib.mkWasixRun {
    name = "lapack-reference-smoke";
    wasixPkgs = [(makeWasmerPackage {package = prog;}).shim];
    script = ''
      out=$(lapack-smoke)
      echo "$out"
      [ "$out" = "ddot=32.0 solve=1.0,2.0 info=0" ]
    '';
  };
}
