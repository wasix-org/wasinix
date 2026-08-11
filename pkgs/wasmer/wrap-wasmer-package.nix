{pkgs}: {
  package,
  name,
  # the source package's pname/version, mirrored onto the shim so consumers
  # (tests) can read wasmerPkgs.<pkg>.{pname,version} off the run-by-name stub.
  pname ? null,
  version ? null,
  # symlinkJoin tree of this package's [dependencies], resolved offline.
  depTree ? null,
  # What `wasmer run` executes. null (default) runs the pkg/<name> source dir
  # (wasmer.toml); pass the built .webc to run the packed artifact instead.
  runTarget ? null,
}: let
  depFlags = pkgs.lib.optionalString (depTree != null) "--offline --include-webc ${depTree}";
in
  pkgs.runCommand "wasmer-wrapped-${package.name}"
  ({meta.mainProgram = name;}
    // pkgs.lib.optionalAttrs (pname != null) {inherit pname;}
    // pkgs.lib.optionalAttrs (version != null) {inherit version;})
  ''
      set -euo pipefail
      mkdir -p "$out/bin"
      # One wrapper per [[command]] in wasmer.toml rather than per bin/*.wasm,
      # since two commands can share one module (bash also serves sh).
      for pkg_dir in "${package}/pkg/"*; do
        [ -f "$pkg_dir/wasmer.toml" ] || continue
        # Run the package with `--entrypoint <command>` rather than the bare
        # .wasm module, so wasmer applies the command's webc annotations
        # (main-args/env), e.g. gunzip = gzip + "-d -f".
        target=${
      if runTarget == null
      then "\"$pkg_dir\""
      else pkgs.lib.escapeShellArg runTarget
    }
        while IFS= read -r cmd_name; do
          [ -n "$cmd_name" ] || continue
          cat > "$out/bin/$cmd_name" <<WRAP
    #!/bin/sh
    exec wasmer run \$WASMER_FLAGS ${depFlags} "$target" --entrypoint "$cmd_name" -- "\$@"
    WRAP
          chmod +x "$out/bin/$cmd_name"
        done < <(sed -n '/^\[\[command\]\]/{n;s/^name = "\(.*\)"$/\1/p;}' "$pkg_dir/wasmer.toml")
      done
  ''
