{
  crossPkgs,
  makeWasmerPackage,
  testLib,
  ...
}: let
  program = crossPkgs.stdenv.mkDerivation {
    pname = "boost-context-test";
    version = "1.0.0";
    dontUnpack = true;
    buildInputs = [crossPkgs.boost];
    buildPhase = ''
      runHook preBuild
      $CXX -std=c++17 ${./context.cpp} -lboost_context -o boost-context-test.wasm
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 boost-context-test.wasm -t "$out/bin"
      runHook postInstall
    '';
    passthru.wasmer.name = "boost-context-test";
  };
in {
  coroutine2 = testLib.mkWasixRun {
    name = "boost-context-coroutine2";
    wasixPkgs = [(makeWasmerPackage {package = program;}).shim];
    script = ''
      [ "$(boost-context-test)" = "boost context ok" ]
    '';
  };
}
