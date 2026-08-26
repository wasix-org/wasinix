{
  commands,
  pkgs,
  entry,
  harnesses,
  ...
}: let
  native = [pkgs.findutils];
  # the find webc ships both find and xargs commands (each gets a shim).
  wasix = builtins.attrValues entry.commands;
  cmp = name: script:
    harnesses.compareShells {
      inherit name script;
      hostPackages = native;
      wasixCommands = wasix;
    };
in {
  version = harnesses.wasixShell {
    name = "find-version";
    shell = commands.bash;
    commands = wasix;
    script = "find --version";
  };

  # traversal works: the save-cwd patch routes cwd restore through getcwd+chdir
  # (wasix has no working fchdir), so find no longer errors on exit.
  traverse = cmp "find-traverse" ''
    find /tmp -maxdepth 0
    mkdir -p t/sub
    : > t/a.txt
    : > t/sub/b.txt
    : > t/c.log
    find t -name '*.txt' | sort
  '';

  exec = harnesses.wasixShell {
    name = "find-exec";
    shell = commands.bash;
    commands = wasix ++ [commands.coreutils];
    script = ''
      mkdir -p t
      printf 'hello\n' > t/a.txt
      test "$(find t -name '*.txt' -exec cat {} \;)" = hello
    '';
  };

  xargs = harnesses.wasixShell {
    name = "find-xargs";
    shell = commands.bash;
    commands = wasix ++ [commands.coreutils];
    script = ''
      test "$(printf 'a\nb\nc\n' | xargs -n1 echo line)" = "$(printf 'line a\nline b\nline c')"
    '';
  };
}
