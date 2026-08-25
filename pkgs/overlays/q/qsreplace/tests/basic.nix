{
  pkgs,
  entry,
  harnesses,
  ...
}: let
  cmp = name: script:
    harnesses.compareShells {
      inherit name script;
      hostPackages = [pkgs.qsreplace];
      wasixCommands = builtins.attrValues entry.commands;
    };
in {
  replace = cmp "qsreplace-replace" ''
    printf '%s\n' 'https://example.com/path?one=1&two=2' | qsreplace value
  '';
  append = cmp "qsreplace-append" ''
    printf '%s\n' 'https://example.com/path?one=1&two=2' | qsreplace -a value
  '';
}
