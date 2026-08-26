{
  commands,
  entry,
  harnesses,
  packageForEntry,
  packages,
  ...
}: let
  program = packages.sameProfile.stdenv.mkDerivation {
    pname = "boost-context-test";
    version = "1.0.0";
    dontUnpack = true;
    buildInputs = [(packageForEntry packages entry)];
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
  coroutine2 = harnesses.wasixShell {
    name = "boost-context-coroutine2";
    shell = commands.bash;
    commands = [
      (harnesses.packageCommand {package = program;})
    ];
    script = ''
      [ "$(boost-context-test)" = "boost context ok" ]
    '';
  };
}
