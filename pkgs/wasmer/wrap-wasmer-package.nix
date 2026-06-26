{pkgs}: {
  package,
  name,
}:
pkgs.runCommand "wasmer-wrapped-${package.name}" {meta.mainProgram = name;} ''
    set -euo pipefail
    mkdir -p "$out/bin"
    for wasm_path in "${package}/pkg/"*/bin/*.wasm; do
      [ -f "$wasm_path" ] || continue
      wasm_file=$(basename "$wasm_path")
      cmd_name="''${wasm_file%.wasm}"
      # The package dir (…/pkg/<name>, holding wasmer.toml). Run the package with
      # `--entrypoint <command>` rather than the bare .wasm module, so wasmer
      # applies the command's webc annotations (main-args/env) — e.g. gunzip =
      # gzip + "-d -f". Running the raw module skips that layer.
      pkg_dir=$(dirname "$(dirname "$wasm_path")")
      cat > "$out/bin/$cmd_name" <<WRAP
  #!/bin/sh
  exec wasmer run \$WASMER_FLAGS "$pkg_dir" --entrypoint "$cmd_name" -- "\$@"
  WRAP
      chmod +x "$out/bin/$cmd_name"
    done
''
