{
  entry,
  pkgs,
  ...
}: {
  interface =
    pkgs.runCommand "wasinix-interface-check" {
      nativeBuildInputs = [entry.package];
    } ''
      wasinix --help >/dev/null
      for command in ${pkgs.lib.escapeShellArgs entry.package.commandAliases}; do
        wasinix "$command" --help >/dev/null
      done
      for shell in bash fish zsh; do
        wasinix completions "$shell" >/dev/null
      done
      touch "$out"
    '';
}
