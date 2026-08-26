{
  harnesses,
  entry,
  commands,
  ...
}: {
  compile-and-link = harnesses.wasixShell {
    name = "clang-compile-and-link";
    shell = commands.bash;
    commands = builtins.attrValues entry.commands ++ [commands."wasm-ld" commands.coreutils];
    runtime.threads = true;
    script = ''
      cat > answer.c <<'EOF'
      #include <stdint.h>
      int32_t answer(void) { return 42; }
      EOF
      clang -c answer.c -o answer.o
      test -s answer.o
      wasm-ld --no-entry --export=answer answer.o -o answer.wasm
      test -s answer.wasm
    '';
  };
}
