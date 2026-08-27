{
  commands,
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
  wasm-link = harnesses.wasixShell {
    name = "lld-wasm-link";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands.coreutils];
    runtime.threads = true;
    host.setup = ''cp ${fixture}/answer.o "$WASIX_TEST_ROOT/answer.o"'';
    script = ''
      wasm-ld --no-entry --export=answer answer.o -o answer.wasm
      test -s answer.wasm
    '';
  };
}
