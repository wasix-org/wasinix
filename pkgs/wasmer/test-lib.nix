{
  pkgs,
  wasmer ? null,
}: let
  lib = pkgs.lib;
  # Set WASMER_BIN=/path/to/wasmer and build with --impure to test against a local binary.
  localWasmerBin = builtins.getEnv "WASMER_BIN";
  # Set WASMER_RUST_BACKTRACE=full (with --impure) to capture a wasmer panic
  # backtrace in a wasix test's output. Bakes RUST_BACKTRACE into the run env.
  localBacktrace = builtins.getEnv "WASMER_RUST_BACKTRACE";

  # Wrap the local binary in a proper nix derivation so the sandbox can access it.
  # autoPatchelfHook re-links it against nixpkgs's own copies of glibc/libffi/etc.
  effectiveWasmer =
    if localWasmerBin != ""
    then
      pkgs.stdenv.mkDerivation {
        name = "local-wasmer";
        src = builtins.path {
          path = localWasmerBin;
          name = "wasmer";
        };
        dontUnpack = true;
        nativeBuildInputs = [pkgs.autoPatchelfHook];
        buildInputs = [pkgs.glibc pkgs.libffi pkgs.zlib pkgs.stdenv.cc.cc.lib];
        installPhase = ''
          mkdir -p $out/bin
          cp $src $out/bin/wasmer
          chmod +x $out/bin/wasmer
        '';
      }
    else if wasmer != null
    then wasmer
    else pkgs.wasmer;

  # Host env vars forwarded into the guest when set. An explicit allowlist
  # rather than --forward-host-env, which would also leak NIX_*, TMPDIR, PATH,
  # etc. Tests needing more pass `forwardEnv`. Values must not contain spaces
  # (they are embedded in the flag string).
  defaultForwardEnv = [
    "HOME"
    "TERM"
    "TZ"
    "LANG"
    "LC_ALL"
    "WASIX_TEST_ROOT"
    "GIT_AUTHOR_DATE"
    "GIT_COMMITTER_DATE"
    "GIT_PROJECT_ROOT"
    "GIT_HTTP_RECEIVE_PACK"
    "GIT_HTTP_EXPORT_ALL"
    "GIT_SSL_CAINFO"
    "SSL_CERT_FILE"
  ];

  # Per-invocation wall-clock timeout in seconds (coreutils `timeout`), so a
  # hung wasm process fails fast instead of hitting Nix's global build timeout.
  # Wasix runs are slower than native, so they get a larger budget.
  defaultTimeout = 300;
  defaultWasixTimeout = 600;

  testExpectation = expectFail: broken:
    if broken != null
    then {
      outcome = "broken";
      reason = broken;
    }
    else if expectFail != null
    then {
      outcome = "xfail";
      reason = expectFail;
    }
    else null;

  # expectFail/broken markers -> onCheckPass/onCheckFail shell. Shared with the
  # emulated build-system checks (pkgs/emulated-check.nix).
  xverdict = import ../lib/xverdict.nix;
in rec {
  inherit defaultForwardEnv defaultTimeout defaultWasixTimeout;

  # The runtime the wasix runs use, for a native test that needs the binary
  # itself (a tool shelling out to `wasmer`) rather than mkWasixRun's shims.
  wasmer = effectiveWasmer;

  # Normalizers for mkScriptComparison's `normalize` hook: executables filtering
  # stdin. The native/wasix argument is ignored (both sides get the same cleanup).
  normalizers = {
    stripAnsi = pkgs.writeShellScript "normalize-strip-ansi" ''
      ${lib.getExe pkgs.gnused} -e 's/\r//' -e 's/\x1b\[[0-9;]*m//g'
    '';
    stripStorePaths = pkgs.writeShellScript "normalize-strip-store-paths" ''
      ${lib.getExe pkgs.gnused} -E 's#/nix/store/[a-z0-9]{32}-#/nix/store/HASH-#g'
    '';
  };
  # Run a bash script with the given packages in PATH.
  # $out is a file containing captured stdout+stderr.
  mkScriptRun = {
    name,
    script,
    packages ? [],
    extra ? [],
    timeout ? defaultTimeout,
  }: let
    scriptFile =
      if builtins.isString script
      then pkgs.writeShellScript "${name}.sh" script
      else script;
  in
    pkgs.runCommand "script-run-${name}" {
      nativeBuildInputs = extra ++ packages;
    } ''
      export HOME=$TMPDIR/home
      mkdir -p "$HOME"
      cd "$(mktemp -d)"
      if ${lib.getExe' pkgs.coreutils "timeout"} ${toString timeout} ${lib.getExe pkgs.bash} -euo pipefail ${scriptFile} >"$out" 2>&1; then
        :
      else
        rc=$?
        [ $rc -eq 124 ] && echo "TIMEOUT: '${name}' exceeded ${toString timeout}s" >&2
        cat "$out" >&2
        exit $rc
      fi
    '';

  # Run a bash script with wasmer-package stubs available by name. Each
  # wasixPkgs binary gets a shim that computes WASMER_FLAGS at invocation time
  # ($HOME, $(pwd)) and calls the original stub, which reads $WASMER_FLAGS.
  #
  # nativePkgs: native tools put directly in PATH (not shimmed)
  # wasixPkgs:  wasmer-package outputs whose stubs get shims
  # wasmerArgs: extra static wasmer flags appended after the defaults, e.g. ["--net"]
  mkWasixRun = {
    name,
    script,
    nativePkgs ? [],
    wasixPkgs ? [],
    wasmer ? effectiveWasmer,
    wasmerArgs ? [],
    forwardEnv ? defaultForwardEnv,
    timeout ? defaultWasixTimeout,
    # See xverdict: expectFail = negative test (failure is correct), broken =
    # known defect (non-blocking, tracked). Composable.
    expectFail ? null,
    broken ? null,
  }: let
    scriptFile =
      if builtins.isString script
      then pkgs.writeShellScript "${name}.sh" script
      else script;
    wasixBinDirs = lib.concatStringsSep " " (map (p: "${p}/bin") wasixPkgs);
    extraFlags = lib.escapeShellArgs wasmerArgs;
    forwardEnvNames = lib.concatStringsSep " " forwardEnv;
    verdict = xverdict {
      inherit name expectFail broken;
      succeed = ":"; # the script already wrote $out
      failHard = ''cat "$out" >&2; exit 1'';
    };
  in
    pkgs.runCommand "script-run-${name}" ({
        nativeBuildInputs = [wasmer] ++ nativePkgs ++ wasixPkgs;
        passthru.wasix.testExpectation = testExpectation expectFail broken;
      }
      # WASMER_RUST_BACKTRACE=full (with --impure) surfaces a wasmer panic
      # backtrace in $out. Set on the host process, not the forwarded guest env.
      // lib.optionalAttrs (localBacktrace != "") {RUST_BACKTRACE = localBacktrace;}) ''
            export HOME=$TMPDIR/home
            ${lib.getExe' pkgs.coreutils "mkdir"} -p "$HOME"

            # The harness and the shims call their own tools by store path: a
            # wasixPkgs entry can put wasm builds of the same names on PATH
            # (coreutils), and those run in the guest.
            shim_dir=$(${lib.getExe' pkgs.coreutils "mktemp"} -d)
            for pkg_bin_dir in ${wasixBinDirs}; do
              [ -d "$pkg_bin_dir" ] || continue
              for original_bin in "$pkg_bin_dir/"*; do
                [ -f "$original_bin" ] || continue
                bin_name=$(${lib.getExe' pkgs.coreutils "basename"} "$original_bin")
                ${lib.getExe' pkgs.coreutils "cat"} > "$shim_dir/$bin_name" <<SHIMEOF
      #!/bin/sh
      env_flags=""
      for _v in ${forwardEnvNames}; do
        _val=\$(${lib.getExe' pkgs.coreutils "printenv"} "\$_v" 2>/dev/null) && env_flags="\$env_flags --env \$_v=\$_val"
      done
      export WASMER_FLAGS="--volume \$HOME:\$HOME --volume \$WASIX_TEST_ROOT:\$WASIX_TEST_ROOT --cwd \$(${lib.getExe' pkgs.coreutils "pwd"})\$env_flags ${extraFlags}"
      exec "$original_bin" "\$@"
      SHIMEOF
                ${lib.getExe' pkgs.coreutils "chmod"} +x "$shim_dir/$bin_name"
              done
            done

            export WASIX_TEST_ROOT="$(${lib.getExe' pkgs.coreutils "mktemp"} -d)"
            cd "$WASIX_TEST_ROOT"
            if PATH="$shim_dir:$PATH" ${lib.getExe' pkgs.coreutils "timeout"} ${toString timeout} ${lib.getExe pkgs.bash} -euo pipefail ${scriptFile} >"$out" 2>&1; then
              ${verdict.onCheckPass}
            else
              rc=$?
              # expectFail asserts the program *cleanly fails* its check; a timeout
              # never completed, so it can't satisfy that — hard-fail the xfail.
              # `broken` makes no such claim (it just tolerates a known defect), so a
              # hang there stays tolerated by the normal verdict below.
              if [ $rc -eq 124 ]; then
                echo "TIMEOUT: '${name}' exceeded ${toString timeout}s" >&2
                ${lib.optionalString (expectFail != null) ''cat "$out" >&2; exit 1''}
              fi
              ${verdict.onCheckFail}
            fi
    '';

  # Run a script in both native and wasix environments.
  # Returns { native, wasix } as output derivation pair.
  mkScriptOutputs = {
    name,
    script,
    common ? [],
    nativePkgs,
    wasixPkgs,
    wasmer ? effectiveWasmer,
    wasmerArgs ? [],
    forwardEnv ? defaultForwardEnv,
    timeout ? defaultTimeout,
    wasixTimeout ? defaultWasixTimeout,
  }: {
    native = mkScriptRun {
      name = "${name}-native";
      inherit script timeout;
      packages = common ++ nativePkgs;
    };
    wasix = mkWasixRun {
      name = "${name}-wasix";
      inherit script wasmer wasmerArgs forwardEnv;
      timeout = wasixTimeout;
      nativePkgs = common;
      inherit wasixPkgs;
    };
  };

  # Run a script in both environments and fail if outputs differ.
  #
  # normalize: optional executable invoked as `normalize native|wasix`, reading from stdin.
  mkScriptComparison = {
    name,
    script,
    common ? [],
    nativePkgs,
    wasixPkgs,
    wasmer ? effectiveWasmer,
    wasmerArgs ? [],
    forwardEnv ? defaultForwardEnv,
    timeout ? defaultTimeout,
    wasixTimeout ? defaultWasixTimeout,
    normalize ? null,
    # expectFail/broken as in xverdict; here the check is the output match, so
    # the marked/expected failure is the outputs differing. Both sides must
    # still run: for a crashing wasix run use mkWasixRun's marker instead.
    expectFail ? null,
    broken ? null,
  }: let
    outputs = mkScriptOutputs {inherit name script common nativePkgs wasixPkgs wasmer wasmerArgs forwardEnv timeout wasixTimeout;};
    process = mode: out:
      if normalize == null
      then out
      else
        pkgs.runCommand "normalize-${name}-${mode}" {} ''
          ${normalize} ${mode} < ${out} > $out
        '';
    nat = process "native" outputs.native;
    was = process "wasix" outputs.wasix;
    verdict = xverdict {
      inherit name expectFail broken;
      succeed = "touch $out";
      failHard = ''${lib.getExe' pkgs.diffutils "diff"} ${nat} ${was} >&2; exit 1'';
    };
  in
    pkgs.runCommand "wasix-compare-${name}" {
      passthru.wasix.testExpectation = testExpectation expectFail broken;
    } ''
      if ${lib.getExe' pkgs.diffutils "diff"} -q ${nat} ${was} >/dev/null 2>&1; then
        ${verdict.onCheckPass}
      else
        ${verdict.onCheckFail}
      fi
    '';
}
