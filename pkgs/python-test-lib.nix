# Shared helpers for running python code on the wasix interpreter under wasmer.
# Used by the wheel suites (python-wheels.nix) and the dependency-closure import
# tests (python-closure-tests.nix).
{
  pkgs,
  lib,
  python3,
  # the self-contained python webc; the interpreter it bundles runs the tests
  # with no host /nix/store
  pythonWebc,
  # wasmer runtime (flake input; null -> pkgs.wasmer)
  wasmer ? null,
}: let
  effWasmer =
    if wasmer != null
    then wasmer
    else pkgs.wasmer;
in {
  # Run a python `script` on the SELF-CONTAINED python webc: the wheel + its
  # dep closure are copied into a plain non-store dir and NO /nix/store is
  # mounted, matching what `pip install --target` gives a bare wasix target, so
  # a wheel reaching a store path (a ctypes .so, a spawned binary) fails here.
  # Only HOME is writable. The script fails the check by raising; the trailing
  # marker confirms it ran through.
  runPython = {
    name,
    wheel,
    script,
    # extra wheels copied in beside `wheel` (test deps, pytest plugins)
    deps ? [],
    timeout ? 600,
    ciTags ? [],
  }: let
    pythonPath = python3.pkgs.makePythonPath ([wheel] ++ deps);
    marker = "PYRUN_OK ${name}";
    file = pkgs.writeText "${name}.py" ''
      ${script}
      print(${builtins.toJSON marker})
    '';
  in
    # stdin from /dev/null: a guest touching a socket makes wasmer prompt for
    # the networking capability, and the prompt blocks until the timeout kills
    # it, losing python's buffered stdout. This runner is the pip-like one and
    # deliberately grants no --net, so the prompt is reachable here.
    pkgs.runCommand name {
      nativeBuildInputs = [effWasmer];
      passthru.wasix = lib.optionalAttrs (ciTags != []) {inherit ciTags;};
    } ''
      export HOME=$TMPDIR/home
      mkdir -p "$HOME"
      webc=$(${pkgs.lib.getExe' pkgs.findutils "find"} ${pythonWebc} -name '*.webc' | head -1)

      site=$TMPDIR/site
      mkdir -p "$site"
      IFS=: read -ra _paths <<< ${lib.escapeShellArg pythonPath}
      for p in "''${_paths[@]}"; do
        [ -d "$p" ] && ${pkgs.lib.getExe pkgs.rsync} -a --chmod=u+w "$p"/ "$site"/
      done
      cp ${file} "$site/__pyrun__.py"

      log=$(mktemp)
      rc=0
      timeout ${toString timeout} wasmer run \
        --volume "$site":/site \
        --mapdir /home:"$HOME" \
        --env HOME=/home \
        --env PYTHONPATH=/site \
        "$webc" -- /site/__pyrun__.py >"$log" 2>&1 </dev/null || rc=$?

      if ${pkgs.lib.getExe' pkgs.gnugrep "grep"} -q ${lib.escapeShellArg marker} "$log" && [ "$rc" -eq 0 ]; then
        cp "$log" "$out"
      else
        echo "python test '${name}' failed (no /nix/store, pip-like):" >&2
        cat "$log" >&2
        exit 1
      fi
    '';
}
