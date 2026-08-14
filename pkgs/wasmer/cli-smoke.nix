# Liveness smoke test for a shipped CLI with no hand-written tests/: try the
# webc's commands with --version, then --help, until one answers. A single
# live command proves the module instantiates and a main runs; a CLI that
# supports neither flag needs passthru.wasmer.smokeArgs or a real tests/.
{
  lib,
  testLib,
}: name: crossPkg: shim: let
  args = crossPkg.passthru.wasmer.smokeArgs or ["--version" "--help"];
in
  testLib.mkWasixRun {
    name = "cli-smoke-${name}";
    wasixPkgs = [shim];
    script = ''
      shopt -s nullglob
      bins=""
      for b in ${shim}/bin/*; do
        bins="$bins $(basename "$b")"
      done
      [ -n "$bins" ] || { echo "no commands in ${name} webc"; exit 1; }

      rc=1
      for cmd in $bins; do
        for a in ${lib.escapeShellArgs args}; do
          echo "== $cmd $a"
          if "$cmd" "$a" >out.txt 2>&1; then
            head -3 out.txt
            rc=0
            break
          fi
        done
        [ "$rc" -eq 0 ] && break
        echo "-- $cmd: no accepted liveness flag; last output:" >&2
        head -5 out.txt >&2
      done
      exit "$rc"
    '';
  }
