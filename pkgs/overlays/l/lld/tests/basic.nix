{
  harnesses,
  entry,
  packages,
  ...
}: let
  fixture = packages.sameProfile.stdenv.mkDerivation {
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
  wasm-link = harnesses.hostShell {
    name = "lld-wasm-link";
    wasixCommands = builtins.attrValues entry.commands;
    wasmerArgs = ["--enable-threads"];
    script = ''
      cp ${fixture}/answer.o answer.o
      wasm-ld --no-entry --export=answer answer.o -o answer.wasm
      test -s answer.wasm
    '';
  };
}
