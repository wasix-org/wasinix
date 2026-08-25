{
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
  version = harnesses.hostShell {
    name = "find-version";
    wasixCommands = wasix;
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

  # -exec and xargs fork+exec correctly (wasix-compat fork shim + asyncify) and
  # cwd is fixed, but the spawned command (cat/echo) isn't resolvable in the
  # wasm runtime PATH. find -exec swallows the exec failure and exits 0, so it
  # surfaces as an output diff; xargs propagates it (non-zero exit). Both
  # tracked until the runtime resolves spawned commands.
  exec = harnesses.compareShells {
    name = "find-exec";
    hostPackages = native;
    wasixCommands = wasix;
    script = ''
      mkdir -p t
      printf 'hello\n' > t/a.txt
      find t -name '*.txt' -exec cat {} \;
    '';
    broken = "find -exec's spawned command (cat) isn't resolvable in the wasm runtime PATH";
  };

  xargs = harnesses.hostShell {
    name = "find-xargs";
    wasixCommands = wasix;
    script = "printf 'a\\nb\\nc\\n' | xargs -n1 echo line";
    broken = "xargs's spawned command (echo) isn't resolvable in the wasm runtime PATH";
  };
}
