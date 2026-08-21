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

      mkdir -p cargo-smoke/src
      cat > cargo-smoke/Cargo.toml <<'EOF'
      [package]
      name = "cargo-smoke"
      version = "0.1.0"
      edition = "2024"
      EOF
      cat > cargo-smoke/src/main.rs <<'EOF'
      fn main() {}
      EOF
      cargo check --offline --manifest-path cargo-smoke/Cargo.toml
    '';
  };
}
