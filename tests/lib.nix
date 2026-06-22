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
in rec {
  # Run a bash script with the given packages in PATH.
  # $out is a file containing captured stdout+stderr.
  mkScriptRun = {
    name,
    script,
    packages ? [],
    extra ? [],
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
      ${pkgs.bash}/bin/bash -euo pipefail ${scriptFile} >"$out" 2>&1 || { cat "$out" >&2; exit 1; }
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
  }: let
    scriptFile =
      if builtins.isString script
      then pkgs.writeShellScript "${name}.sh" script
      else script;
    wasixBinDirs = lib.concatStringsSep " " (map (p: "${p}/bin") wasixPkgs);
    extraFlags = lib.escapeShellArgs wasmerArgs;
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
      export WASMER_FLAGS="--forward-host-env --volume /nix/store:/nix/store --volume \$HOME:\$HOME --volume \$WASIX_TEST_ROOT:\$WASIX_TEST_ROOT --cwd \$(pwd) ${extraFlags}"
      exec "$original_bin" "\$@"
      SHIMEOF
                chmod +x "$shim_dir/$bin_name"
              done
            done

            export WASIX_TEST_ROOT="$(mktemp -d)"
            cd "$WASIX_TEST_ROOT"
            PATH="$shim_dir:$PATH" ${pkgs.bash}/bin/bash -euo pipefail ${scriptFile} >"$out" 2>&1 || { cat "$out" >&2; exit 1; }
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
  }: {
    native = mkScriptRun {
      name = "${name}-native";
      inherit script;
      packages = common ++ nativePkgs;
    };
    wasix = mkWasixRun {
      name = "${name}-wasix";
      inherit script wasmer wasmerArgs;
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
    normalize ? null,
  }: let
    outputs = mkScriptOutputs {inherit name script common nativePkgs wasixPkgs wasmer wasmerArgs;};
    process = mode: out:
      if normalize == null
      then out
      else
        pkgs.runCommand "normalize-${name}-${mode}" {} ''
          ${normalize} ${mode} < ${out} > $out
        '';
  in
    pkgs.runCommand "wasix-compare-${name}" {} ''
      ${pkgs.diffutils}/bin/diff ${process "native" outputs.native} ${process "wasix" outputs.wasix}
      touch $out
    '';
}
