{
  testLib,
  wasmerPkgs,
  ...
}: let
  wasix = [wasmerPkgs.llvm];
in {
  ir-roundtrip = testLib.mkWasixRun {
    name = "llvm-ir-roundtrip";
    wasixPkgs = wasix;
    wasmerArgs = ["--enable-threads"];
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

  wasm-object = testLib.mkWasixRun {
    name = "llvm-wasm-object";
    wasixPkgs = wasix;
    wasmerArgs = ["--enable-threads"];
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
