{
  pkgs,
  wasmer ? null,
}: let
  lib = pkgs.lib;
  # Set WASMER_BIN=/path/to/wasmer and build with --impure to test against a local binary.
  localWasmerBin = builtins.getEnv "WASMER_BIN";

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

  # Host env vars forwarded into the guest (only if set, at invocation). An explicit
  # allowlist, not wasmer's blanket --forward-host-env — which would leak sandbox
  # noise (NIX_*, TMPDIR, PATH, …) into the wasm process. Tests needing more pass
  # `forwardEnv`. (Values must be space-free — they ride in the flag string.)
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

  # Wall-clock budget (seconds) for a single script invocation, enforced with
  # coreutils `timeout`. Guards against a hung wasm process blocking until Nix's
  # global build timeout. Wasix runs interpret/JIT the module, so they get a
  # larger budget than native. Override per-test via the helpers' `timeout` arg.
  defaultTimeout = 300;
  defaultWasixTimeout = 600;

  # Decide a test's verdict, honoring two optional, COMPOSABLE markers:
  #
  #   expectFail = "why failing is correct"   — a negative test: the EXPECTED
  #       outcome is the program's check *failing*, so the pass/fail is inverted.
  #   broken     = "why it's wrong + link"    — a known defect: the test does NOT
  #       yet meet its expectation; tolerate that (don't block CI) but track it.
  #
  # Set together they read naturally — e.g. `expectFail "should reject bad input"`
  # + `broken "but currently accepts it, see #42"`: a negative test whose expected
  # failure doesn't happen yet because of a tracked bug.
  #
  # `expectFail` defines what "meeting expectation" means (fail, vs the default
  # pass); `broken` says we currently don't meet it. So:
  #   * expectation met, not broken        -> succeed
  #   * expectation unmet, marked broken    -> log "known broken", succeed (non-blocking)
  #   * expectation met while marked broken -> XPASS: hard-fail "remove broken marker"
  #   * expectation unmet, expectFail, not broken -> XPASS: hard-fail (regression)
  #   * unmet, unmarked                     -> failHard
  # The XPASS hard-fails stop a stale marker from masking a future regression.
  #
  # Caller runs the check and branches: `if <check>; then ${onCheckPass} else ${onCheckFail} fi`.
  #   succeed:  shell that makes the derivation succeed
  #   failHard: shell for a genuine, unmarked failure (report + exit 1)
  xverdict = {
    name,
    expectFail ? null,
    broken ? null,
    succeed,
    failHard,
  }: let
    expectsFail = expectFail != null;
    isBroken = broken != null;
    tolerateBroken = ''echo "known broken: '${name}' (${broken}) — not blocking CI." >&2; ${succeed}'';
    expectedFailOk = ''echo "expected failure: '${name}' (${expectFail})." >&2; ${succeed}'';
    xpassRegression = ''echo "XPASS: '${name}' was expected to FAIL (${expectFail}) but passed — fix the test or investigate the regression." >&2; exit 1'';
    xpassRemoveBroken = ''echo "XPASS: '${name}' is marked broken (${broken}) but now behaves as expected — remove the broken marker." >&2; exit 1'';
  in {
    # the program's check succeeded (expectation = met unless expectFail)
    onCheckPass =
      if !expectsFail
      then
        if isBroken
        then xpassRemoveBroken
        else succeed
      else if isBroken
      then tolerateBroken
      else xpassRegression;
    # the program's check failed (expectation = met only if expectFail)
    onCheckFail =
      if expectsFail
      then
        if isBroken
        then xpassRemoveBroken
        else expectedFailOk
      else if isBroken
      then tolerateBroken
      else failHard;
  };
in rec {
  inherit defaultForwardEnv defaultTimeout defaultWasixTimeout;

  # Reusable output normalizers for mkScriptComparison's `normalize` hook: each is
  # an executable filtering stdin (its `native`/`wasix` arg is ignored — the same
  # cleanup applies to both sides).
  normalizers = {
    stripAnsi = pkgs.writeShellScript "normalize-strip-ansi" ''
      ${pkgs.gnused}/bin/sed -e 's/\r//' -e 's/\x1b\[[0-9;]*m//g'
    '';
    stripStorePaths = pkgs.writeShellScript "normalize-strip-store-paths" ''
      ${pkgs.gnused}/bin/sed -E 's#/nix/store/[a-z0-9]{32}-#/nix/store/HASH-#g'
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
      if ${pkgs.coreutils}/bin/timeout ${toString timeout} ${pkgs.bash}/bin/bash -euo pipefail ${scriptFile} >"$out" 2>&1; then
        :
      else
        rc=$?
        [ $rc -eq 124 ] && echo "TIMEOUT: '${name}' exceeded ${toString timeout}s" >&2
        cat "$out" >&2
        exit $rc
      fi
    '';

  # Run a bash script with wasmer-package stubs available by name.
  #
  # For each binary in wasixPkgs, generates a shim that:
  #   1. Computes WASMER_FLAGS at invocation time ($HOME, $(pwd) resolved then)
  #   2. Calls the original wasmer-package stub, which reads $WASMER_FLAGS
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
    # See xverdict: expectFail = negative test (failure is correct); broken =
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
    pkgs.runCommand "script-run-${name}" {
      nativeBuildInputs = [wasmer] ++ nativePkgs ++ wasixPkgs;
    } ''
            export HOME=$TMPDIR/home
            mkdir -p "$HOME"

            shim_dir=$(mktemp -d)
            for pkg_bin_dir in ${wasixBinDirs}; do
              [ -d "$pkg_bin_dir" ] || continue
              for original_bin in "$pkg_bin_dir/"*; do
                [ -f "$original_bin" ] || continue
                bin_name=$(basename "$original_bin")
                cat > "$shim_dir/$bin_name" <<SHIMEOF
      #!/bin/sh
      # Forward only the allowlisted host vars that are actually set (not wasmer's
      # blanket --forward-host-env, which would leak NIX_*/TMPDIR/PATH/… too).
      env_flags=""
      for _v in ${forwardEnvNames}; do
        _val=\$(printenv "\$_v" 2>/dev/null) && env_flags="\$env_flags --env \$_v=\$_val"
      done
      export WASMER_FLAGS="--volume /nix/store:/nix/store --volume \$HOME:\$HOME --volume \$WASIX_TEST_ROOT:\$WASIX_TEST_ROOT --cwd \$(pwd)\$env_flags ${extraFlags}"
      exec "$original_bin" "\$@"
      SHIMEOF
                chmod +x "$shim_dir/$bin_name"
              done
            done

            export WASIX_TEST_ROOT="$(mktemp -d)"
            cd "$WASIX_TEST_ROOT"
            if PATH="$shim_dir:$PATH" ${pkgs.coreutils}/bin/timeout ${toString timeout} ${pkgs.bash}/bin/bash -euo pipefail ${scriptFile} >"$out" 2>&1; then
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
    # expectFail/broken as in xverdict — here the "check" is the output match, so
    # the marked/expected failure is the outputs *differing*. Both sides must
    # still run; a crashing wasix run isn't comparable — use mkWasixRun's marker.
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
      failHard = ''${pkgs.diffutils}/bin/diff ${nat} ${was} >&2; exit 1'';
    };
  in
    pkgs.runCommand "wasix-compare-${name}" {} ''
      if ${pkgs.diffutils}/bin/diff -q ${nat} ${was} >/dev/null 2>&1; then
        ${verdict.onCheckPass}
      else
        ${verdict.onCheckFail}
      fi
    '';
}
