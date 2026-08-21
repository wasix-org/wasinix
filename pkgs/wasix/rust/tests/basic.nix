{
  harnesses,
  entry,
  commands,
  ...
}: {
  compile = harnesses.hostShell {
    name = "rust-compile";
    wasixCommands = builtins.attrValues entry.commands ++ [commands."wasm-ld"];
    wasmerArgs = ["--enable-threads"];
    timeout = 600;
    script = ''
      cat > answer.rs <<'EOF'
      #[no_mangle]
      pub extern "C" fn answer() -> i32 { 42 }
      fn main() {}
      EOF
      rustc answer.rs -C linker=/bin/wasm-ld -o answer.wasm
      test -s answer.wasm

      mkdir -p cargo-check/src
      cat > cargo-check/Cargo.toml <<'EOF'
      [package]
      name = "cargo-check"
      version = "0.1.0"
      edition = "2024"
      EOF
      cat > cargo-check/src/main.rs <<'EOF'
      fn main() {}
      EOF
      cargo check --offline --manifest-path cargo-check/Cargo.toml
    '';
  };
}
