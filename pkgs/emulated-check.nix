# Run the package's own checkPhase under wasmer. The package build captures
# its test tree as the `check` output (lib/check-output.nix); this file
# restores that tree and runs the real phase with the runtime present, so a
# wasmer bump re-runs tests without recompiling. See docs/architecture.md.
{
  lib,
  pkgs,
  wasixRun,
}: let
  xverdict = import ./lib/xverdict.nix;
  stub = "${wasixRun.stub}/bin/wasix-run";
  wasmer = wasixRun.run.wasmer;

  # Test suites execute wasm programs by filename. Keep the wasm bytes in a
  # sibling file because Wasmer and guest exec both require the wasm magic at
  # byte zero.
  shebangExecs = ''
    _shebang_root="$PWD"
    find . -type f -perm -u+x \
      ! -name '*.o' ! -name '*.a' ! -name '*.so' ! -name '*.so.*' -print0 |
    while IFS= read -r -d "" _f; do
      [ "$(od -An -tx1 -N4 "$_f" 2>/dev/null | tr -d ' \n')" = "0061736d" ] || continue
      mv "$_f" "$_f.wasm"
      printf '#!%s\nexec %s %s "$@"\n' \
        ${lib.escapeShellArg pkgs.runtimeShell} \
        ${lib.escapeShellArg stub} \
        "$_shebang_root/''${_f#./}.wasm" \
        > "$_f"
      chmod +x "$_f"
    done
  '';

  restore = checkOut:
    ''
      _wasix_runner_out="$out"
      _wasix_runner_build_top="$NIX_BUILD_TOP"
      _wasix_runner_home="$HOME"
      _wasix_runner_path="$PATH"
      source ${checkOut}/environment.sh
      export NIX_BUILD_TOP="$_wasix_runner_build_top"
      export TMPDIR="$NIX_BUILD_TOP"
      export TMP="$TMPDIR"
      export TEMP="$TMPDIR"
      export TEMPDIR="$TMPDIR"
      export HOME="$_wasix_runner_home"
      export PATH="$PATH:$_wasix_runner_path"
      _build_rel="$(cat ${checkOut}/.builddir)"
      _src_rel="''${_build_rel%%/*}"
      ${pkgs.zstd}/bin/zstd -dc "${checkOut}/tree.tar.zst" | tar -C "$NIX_BUILD_TOP" -xf -
      chmod -R u+w "$NIX_BUILD_TOP/$_src_rel"
      cd "$NIX_BUILD_TOP/$_build_rel"
    ''
    + shebangExecs;

  # Python suites need writable temp and cache paths under /home. Normalize
  # missing thread IDs and faulthandler's unsupported fd operations at startup.
  guestSiteCustomize = pkgs.writeTextDir "sitecustomize.py" ''
    import os, tempfile

    try:
        os.makedirs("/home/tmp", exist_ok=True)
        os.environ["TMPDIR"] = "/home/tmp"
        tempfile.tempdir = "/home/tmp"
    except Exception:
        pass

    try:
        _pa = os.environ.get("PYTEST_ADDOPTS", "")
        os.environ["PYTEST_ADDOPTS"] = (_pa + " -o cache_dir=/home/tmp/pytest-cache").strip()
    except Exception:
        pass

    try:
        import threading
        if not hasattr(threading, "get_native_id"):
            threading.get_native_id = threading.get_ident
    except Exception:
        pass

    try:
        import faulthandler
        for _n in ("enable", "dump_traceback_later", "cancel_dump_traceback_later"):
            setattr(faulthandler, _n, lambda *a, **k: None)
    except Exception:
        pass

  '';

  # Cap on a check's output: a suite looping on one error can fill the
  # builder's disk. head -c SIGPIPEs the producer at the cap, and the check
  # fails.
  outputCap = 64 * 1024 * 1024;

  # Wall-clock ceiling for a suite; the cap separately catches loud loops,
  # and nix's own timeout is unset. Genuinely long suites raise it via
  # passthru.wasix.emulatedCheck.timeout.
  defaultTimeout = 1200;

  # Poll a backgrounded runPhase for the deadline while retaining its status
  # through the capped logging pipeline.
  wrappedCheck = name: spec: phase: let
    timeout = spec.timeout or defaultTimeout;
    verdict = xverdict {
      inherit name;
      expectFail = spec.expectFail or null;
      broken = spec.broken or null;
      succeed = ":";
      failHard = ''exit 1'';
    };
  in ''
    _log="$NIX_BUILD_TOP/check.log"
    set +e
    (
      (
      set -e
      ${
      if phase == "pythonCheckPhase"
      then ''
        if declare -F pytestCheckPhase >/dev/null; then runPhase pytestCheckPhase
        elif declare -F unittestCheckPhase >/dev/null; then runPhase unittestCheckPhase
        else runPhase installCheckPhase; fi
      ''
      else "runPhase ${phase}"
    }
    ) 2>&1 | stdbuf -o0 head -c ${toString outputCap} | tee "$_log"
      exit "''${PIPESTATUS[0]}"
    ) &
    _job=$!
    _deadline=$(( $(date +%s) + ${toString timeout} ))
    _timedout=
    while kill -0 "$_job" 2>/dev/null; do
      if [ "$(date +%s)" -ge "$_deadline" ]; then
        _timedout=1
        kill -TERM "$_job" 2>/dev/null; sleep 5; kill -KILL "$_job" 2>/dev/null
        break
      fi
      sleep 5
    done
    wait "$_job"; _rc=$?
    set -e

    if [ -n "$_timedout" ]; then
      echo "check '${name}' timed out after ${toString timeout}s (output stayed below the cap)" >&2
      exit 1
    fi
    if [ "$_rc" -eq 141 ]; then
      echo "check '${name}' exceeded the ${toString (outputCap / 1024 / 1024)}MB output cap; treating as a runaway suite" >&2
      exit 1
    fi
    if grep -q 'panicked at .*lib/wasix/' "$_log"; then
      echo "check '${name}' triggered an internal Wasmer/WASIX panic" >&2
      exit 1
    fi
    if [ "$_rc" -eq 0 ]; then
      ${verdict.onCheckPass}
    else
      ${verdict.onCheckFail}
    fi
  '';
in {
  inherit restore shebangExecs;

  # The package's emulated upstream check derivation. Callers attach it as
  # `passthru.tests.upstream`; this layer knows nothing about synthetic checks.
  checkFor = {
    drv,
    # timeout plus the expectFail/broken verdict; nothing derivable
    spec ? {},
    # "checkPhase" (C suites) or "pythonCheckPhase" (buildPythonPackage)
    phase ? "checkPhase",
    # Host-platform packages the guest needs on its path; the check hooks
    # propagate build-platform ones, which a wasm interpreter cannot import.
    guestInputs ? [],
    name ? "${lib.getName drv}-check",
  }:
    lib.throwIf (!(drv ? check))
    "${name}: the package has no `check` output, so it declares no suite (doCheck)"
    pkgs.stdenvNoCC.mkDerivation {
      name = "${name}-${drv.version or "0"}";
      dontUnpack = true;
      phases = ["wasixRestorePhase" "wasixCheckPhase" "wasixInstallPhase"];
      nativeBuildInputs = guestInputs ++ [wasixRun.stub pkgs.writableTmpDirAsHomeHook];
      wasixRestorePhase =
        restore drv.check
        + ''
          export WASIX_WASMER=${lib.escapeShellArg "${wasmer}/bin/wasmer"}
          export WASIX_RUN_FLAGS=--net
          export WASIX_RUN_ENV_ALL=1
          export PYTHON_BASIC_REPL=1
          export PYTHONUNBUFFERED=1
          export CI=true
          export enableParallelChecking=false
          ${
            if phase == "pythonCheckPhase"
            then "export doInstallCheck=1"
            else "export doCheck=1"
          }
        ''
        + lib.optionalString (phase == "pythonCheckPhase") ''
          PYTHONPATH=
          _python_pp=
          _seen=" "
          _queue=${lib.escapeShellArg (lib.concatStringsSep " " (map toString guestInputs))}
          if [ -f ${drv}/nix-support/propagated-build-inputs ]; then
            _queue="$_queue $(cat ${drv}/nix-support/propagated-build-inputs)"
          fi
          while [ -n "''${_queue// /}" ]; do
            _next=
            for _d in $_queue; do
              case "$_seen" in *" $_d "*) continue ;; esac
              _seen="$_seen$_d "
              for _sp in "$_d"/lib/python*/site-packages; do
                [ -d "$_sp" ] || continue
                _python_pp="$_sp''${_python_pp:+:$_python_pp}"
              done
              if [ -f "$_d/nix-support/propagated-build-inputs" ]; then
                _next="$_next $(cat "$_d/nix-support/propagated-build-inputs")"
              fi
            done
            _queue="$_next"
          done
          PYTHONPATH="$_python_pp"
          for _sp in ${drv}/lib/python*/site-packages; do
            [ -d "$_sp" ] && PYTHONPATH="$_sp''${PYTHONPATH:+:$PYTHONPATH}"
          done
          PYTHONPATH=${guestSiteCustomize}''${PYTHONPATH:+:$PYTHONPATH}
          export PYTHONPATH
          echo "guest PYTHONPATH=$PYTHONPATH"
        '';
      wasixCheckPhase = wrappedCheck name spec phase;
      wasixInstallPhase = ''
        mkdir -p "$_wasix_runner_out"
        cp "$_log" "$_wasix_runner_out/check.log"
      '';
    };
}
