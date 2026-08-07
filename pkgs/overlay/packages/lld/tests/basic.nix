{
  testLib,
  wasmerPkgs,
  crossPkgs,
  ...
}: let
  fixture = crossPkgs.stdenv.mkDerivation {
    pname = "lld-wasm-fixture";
    version = "1";
    dontUnpack = true;
    buildPhase = ''
      cat > answer.c <<'EOF'
      int answer(void) { return 42; }
      EOF
      $CC -c answer.c -o answer.o
    '';
    installPhase = ''
      mkdir -p "$out"
      cp answer.o "$out/answer.o"
    '';
  };
in {
  wasm-link = testLib.mkWasixRun {
    name = "lld-wasm-link";
    wasixPkgs = [wasmerPkgs.lld];
    wasmerArgs = ["--enable-threads"];
    script = ''
      cp ${fixture}/answer.o answer.o
      wasm-ld --no-entry --export=answer answer.o -o answer.wasm
      test -s answer.wasm
    '';
  };
}
