{
  commands,
  harnesses,
  entry,
  ...
}: let
  wasix = builtins.attrValues entry.commands;
in {
  ir-roundtrip = harnesses.wasixShell {
    name = "llvm-ir-roundtrip";
    shell = commands.bash;
    commands = wasix ++ [commands.grep];
    runtime.threads = true;
    script = ''
      cat > input.ll <<'EOF'
      define i32 @answer() {
        ret i32 42
      }
      EOF
      llvm-as input.ll -o input.bc
      llvm-dis input.bc -o output.ll
      grep -F 'ret i32 42' output.ll
    '';
  };

  wasm-object = harnesses.wasixShell {
    name = "llvm-wasm-object";
    shell = commands.bash;
    commands = wasix ++ [commands.grep];
    runtime.threads = true;
    script = ''
      cat > input.ll <<'EOF'
      target triple = "wasm32-unknown-wasi"
      define i32 @answer() {
        ret i32 42
      }
      EOF
      llc -mtriple=wasm32-unknown-wasi -filetype=obj input.ll -o output.o
      llvm-readobj --file-headers output.o > headers
      grep -F 'Format: WASM' headers
      grep -F 'Arch: wasm32' headers
    '';
  };
}
