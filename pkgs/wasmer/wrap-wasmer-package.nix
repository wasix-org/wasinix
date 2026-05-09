{ pkgs }:
{ package, name }:
pkgs.runCommand "wasmer-wrapped-${package.name}" { meta.mainProgram = name; } ''
  set -euo pipefail
  mkdir -p "$out/bin"
  for wasm_path in "${package}/pkg/"*/bin/*.wasm; do
    [ -f "$wasm_path" ] || continue
    wasm_file=$(basename "$wasm_path")
    cmd_name="''${wasm_file%.wasm}"
    cat > "$out/bin/$cmd_name" <<WRAP
#!/bin/sh
exec wasmer run \$WASMER_FLAGS "$wasm_path" -- "\$@"
WRAP
    chmod +x "$out/bin/$cmd_name"
  done
''
