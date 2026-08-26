{
  entry,
  harnesses,
  pkgs,
  ...
}: let
  wasix = builtins.attrValues entry.commands;
  compare = name: script:
    harnesses.compareShells {
      inherit name script;
      hostPackages = [pkgs.diffutils];
      wasixCommands = wasix;
    };
in {
  files = compare "diff-files" ''
    printf 'same\nold\n' > old
    printf 'same\nnew\n' > new
    diff old new || test "$?" -eq 1
  '';

  recursive = compare "diff-recursive" ''
    mkdir -p old/sub new/sub
    printf 'same\n' > old/same
    printf 'same\n' > new/same
    printf 'old\n' > old/sub/value
    printf 'new\n' > new/sub/value
    diff -r old new || test "$?" -eq 1
  '';
}
