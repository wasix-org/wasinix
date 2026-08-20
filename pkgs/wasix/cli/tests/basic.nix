{
  pkgs,
  testLib,
  wasmerPackages,
  wasmerPkgs,
  ...
}: {
  manifest = pkgs.runCommand "cli-manifest" {} ''
    manifest=${wasmerPackages.cli.pkg}/pkg/cli/wasmer.toml
    grep -Fx '"wasmer/bash" = "*"' "$manifest"
    grep -Fx 'module = "wasmer/bash:bash"' "$manifest"
    grep -Fx 'atom = "wasmer/bash:bash"' "$manifest"
    if grep -Fq '[[module]]' "$manifest"; then
      echo 'cli embeds a module instead of re-exporting bash' >&2
      exit 1
    fi
    touch "$out"
  '';

  find = testLib.mkWasixRun {
    name = "cli-find";
    wasixPkgs = [wasmerPkgs.cli];
    script = ''
      test "$(bash -c 'find /tmp -maxdepth 0')" = /tmp
    '';
  };
}
