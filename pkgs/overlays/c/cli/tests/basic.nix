{
  pkgs,
  harnesses,
  entry,
  packageForEntry,
  packages,
  ...
}: {
  manifest = pkgs.runCommand "cli-manifest" {} ''
    manifest=${(packageForEntry packages entry).artifacts.pkg}/pkg/cli/wasmer.toml
    grep -E '^"wasmer/bash" = "=[^"]+"$' "$manifest"
    grep -E '^"wasmer/coreutils" = "=[^"]+"$' "$manifest"
    if grep -Eq '^"[^"]+" = "\*"$' "$manifest"; then
      echo 'cli has an unpinned dependency' >&2
      exit 1
    fi
    grep -Fx 'module = "wasmer/bash:bash"' "$manifest"
    grep -Fx 'atom = "wasmer/bash:bash"' "$manifest"
    if grep -Fq '[[module]]' "$manifest"; then
      echo 'cli embeds a module instead of re-exporting bash' >&2
      exit 1
    fi
    touch "$out"
  '';

  find = harnesses.wasixShell {
    name = "cli-find";
    shell = entry.commands.bash;
    script = ''
      test "$(bash -c 'find /tmp -maxdepth 0')" = /tmp
    '';
  };

  identity = harnesses.wasixShell {
    name = "cli-identity";
    shell = entry.commands.bash;
    script = ''
      test "$(whoami)" = root
      test "$(id -un)" = root
      test "$(id -gn)" = root
      test "$(groups)" = root
    '';
  };
}
