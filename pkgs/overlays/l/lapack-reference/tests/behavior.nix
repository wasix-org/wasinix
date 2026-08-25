# Cross-build a C program against the wasix reference LAPACK/BLAS via pkg-config,
# the same discovery path scipy uses, and run it under wasmer. lapack-reference is
# PIC-only, hence crossPkgsPic.
{
  harnesses,
  entry,
  packageForEntry,
  packages,
  ...
}: let
  crossPkgs = packages.sameProfile;
  prog = crossPkgs.stdenv.mkDerivation {
    pname = "lapack-behavior";
    version = "1.0.0";
    dontUnpack = true;
    nativeBuildInputs = [crossPkgs.pkg-config];
    buildInputs = [(packageForEntry packages entry)];
    # Cross pkg-config is the target-prefixed wrapper in $PKG_CONFIG; bare
    # `pkg-config` is not on PATH.
    buildPhase = ''
      runHook preBuild
      $CC ${./behavior.c} -o lapack-behavior.wasm $("$PKG_CONFIG" --cflags --libs --static lapack cblas)
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      install -Dm755 lapack-behavior.wasm -t "$out/bin"
      runHook postInstall
    '';
    passthru.wasmer.name = "lapack-behavior";
  };
in {
  behavior = harnesses.hostShell {
    name = "lapack-reference-behavior";
    wasixCommands = [
      (harnesses.packageCommand {package = prog;})
    ];
    script = ''
      out=$(lapack-behavior)
      echo "$out"
      [ "$out" = "ddot=32.0 solve=1.0,2.0 info=0" ]
    '';
  };
}
