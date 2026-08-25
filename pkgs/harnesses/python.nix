{
  pkgs,
  lib,
  wasmer,
  python3,
  pythonWebc,
  name,
  wheel,
  script,
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
  pkgs.runCommand name {
    nativeBuildInputs = [wasmer];
    passthru.wasinix = lib.optionalAttrs (ciTags != []) {ci.tags = ciTags;};
  } ''
    export HOME=$TMPDIR/home
    mkdir -p "$HOME"
    webc=$(${lib.getExe' pkgs.findutils "find"} ${pythonWebc} -name '*.webc' | head -1)

    site=$TMPDIR/site
    mkdir -p "$site"
    IFS=: read -ra _paths <<< ${lib.escapeShellArg pythonPath}
    for p in "''${_paths[@]}"; do
      [ -d "$p" ] && ${lib.getExe pkgs.rsync} -a --chmod=u+w "$p"/ "$site"/
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

    if ${lib.getExe' pkgs.gnugrep "grep"} -q ${lib.escapeShellArg marker} "$log" && [ "$rc" -eq 0 ]; then
      cp "$log" "$out"
    else
      echo "python test '${name}' failed (no /nix/store, pip-like):" >&2
      cat "$log" >&2
      exit 1
    fi
  ''
