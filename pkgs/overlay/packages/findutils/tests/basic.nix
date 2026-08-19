{
  pkgs,
  wasmerPkgs,
  testLib,
  ...
}: let
  native = [pkgs.findutils];
  # the find webc ships both find and xargs commands (each gets a shim).
  wasix = [wasmerPkgs.find];
  cmp = name: script:
    testLib.mkScriptComparison {
      inherit name script;
      nativePkgs = native;
      wasixPkgs = wasix;
    };
in {
  version = testLib.mkWasixRun {
    name = "find-version";
    wasixPkgs = wasix;
    script = "find --version";
  };

  # traversal works: the save-cwd patch routes cwd restore through getcwd+chdir
  # (wasix has no working fchdir), so find no longer errors on exit.
  traverse = cmp "find-traverse" ''
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
  exec = testLib.mkScriptComparison {
    name = "find-exec";
    nativePkgs = native;
    wasixPkgs = wasix;
    script = ''
      mkdir -p t
      printf 'hello\n' > t/a.txt
      find t -name '*.txt' -exec cat {} \;
    '';
    broken = "find -exec's spawned command (cat) isn't resolvable in the wasm runtime PATH";
  };

  xargs = testLib.mkWasixRun {
    name = "find-xargs";
    wasixPkgs = wasix;
    script = "printf 'a\\nb\\nc\\n' | xargs -n1 echo line";
    broken = "xargs's spawned command (echo) isn't resolvable in the wasm runtime PATH";
  };
}
