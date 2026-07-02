# The shipped Python wheels + import smoke-tests. Exposes each wheel in
# overlay/python-packages/wheels.nix as pythonWheels.<attr> (the wasm cross build) and
# .tests (an import run under wasmer), for `.#pythonWheels.<attr>` targets + checks.wheel-<attr>.
{
  pkgs,
  lib,
  # the wasix cpython at its ehpic profile; its bin/python3.13.wasm runs the smoke-tests.
  python3,
  # wasmer runtime for the smoke-tests (flake input; null -> pkgs.wasmer).
  wasmer ? null,
  mkTestGroup,
}: let
  effWasmer =
    if wasmer != null
    then wasmer
    else pkgs.wasmer;

  wheelList = import ./overlay/python-packages/wheels.nix;
  pyImportOf = e: e.pyImport or (lib.replaceStrings ["-"] ["_"] e.attr);

  # Smoke-test: `import <mod>` under wasmer with /nix/store mounted (so the wheel's C-extension
  # dylibs resolve at load). A clean import proves the wheel cross-built AND dynamically loads.
  importTest = e: let
    wheel = python3.pkgs.${e.attr};
    pythonPath = python3.pkgs.makePythonPath [wheel];
    mod = pyImportOf e;
  in
    pkgs.runCommand "wheel-import-${e.attr}" {
      nativeBuildInputs = [effWasmer];
    } ''
      export HOME=$TMPDIR/home
      mkdir -p "$HOME"
      log=$(mktemp)
      # Map a writable HOME into the guest and point HOME at it: some wheels resolve a
      # config/cache dir at import (e.g. matplotlib.get_configdir → "Could not determine
      # home directory" with no HOME). Harmless for wheels that don't read it.
      if timeout 600 wasmer run \
        --volume /nix/store:/nix/store \
        --mapdir /home:"$HOME" \
        --env HOME=/home \
        --env PYTHONPATH=${lib.escapeShellArg pythonPath} \
        ${python3}/bin/python${python3.pythonVersion}.wasm -- \
        -c 'import ${mod}; print("WHEEL_IMPORT_OK ${mod}")' >"$log" 2>&1; then
        if ${pkgs.gnugrep}/bin/grep -q "WHEEL_IMPORT_OK ${mod}" "$log"; then
          cp "$log" "$out"
        else
          echo "import ${mod} did not confirm OK for wheel '${e.attr}':" >&2
          cat "$log" >&2
          exit 1
        fi
      else
        echo "wasmer run failed importing ${mod} (wheel '${e.attr}'):" >&2
        cat "$log" >&2
        exit 1
      fi
    '';

  # python3.pkgs.<attr> with .tests added (passthru-only, so the store path is
  # unchanged). Inherited nixpkgs passthru.tests are dropped: they are x86 test
  # suites that would leak into `checks`.
  mkWheel = e:
    (python3.pkgs.${e.attr}).overrideAttrs (o: {
      passthru =
        removeAttrs (o.passthru or {}) ["tests"]
        // lib.optionalAttrs (!(e.skipTest or false)) {
          tests = mkTestGroup "wheel-${e.attr}" {import = importTest e;};
        };
    });
in
  lib.listToAttrs (map (e: lib.nameValuePair e.attr (mkWheel e)) wheelList)
