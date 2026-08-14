# The wasix cross stdenv: a nixpkgs cc-wrapper around a shim that execs
# wasixcc/wasix++ with this profile's WASIXCC_* env. Installed as
# config.replaceCrossStdenv by set/mk-pkgs.nix.
{
  lib,
  toolchain,
  referenceScanner,
  snapshotZstd,
}: {
  buildPackages,
  baseStdenv,
}: let
  inherit (import ../lib/check-output.nix {inherit lib referenceScanner snapshotZstd;}) checkOutputArgs;
  hp = baseStdenv.hostPlatform;
  exceptions = hp.wasmExceptions or null;
  pic = hp.wasmPic or false;

  # DISCARD_UNSUPPORTED_FLAGS is shim-specific: nixpkgs' generic flags include
  # ones wasm rejects.
  env = import ../toolchain/env.nix {inherit lib;};
  shimEnv = env.exportsOf (
    env.profileEnv {
      wasmExceptions = exceptions;
      inherit pic;
    }
    // env.autoconfEnv
    // {WASIXCC_DISCARD_UNSUPPORTED_FLAGS = "yes";}
  );

  # -fno-exceptions is ABI-wrong under any EH profile and wasixcc hard-errors on it
  # under PIC, so strip what packages pass. cc-wrapper collapses a long command
  # line into an @response-file, so rewrite that in place too.
  stripNoExceptions = lib.optionalString (exceptions != null && exceptions != "no") ''
    _args=()
    for _a in "$@"; do
      case "$_a" in
        -fno-exceptions | -fno-cxx-exceptions) ;;
        @*)
          _rf=''${_a#@}
          _keep=()
          while IFS= read -r _l; do
            case "$_l" in
              -fno-exceptions | -fno-cxx-exceptions) ;;
              *) _keep+=("$_l") ;;
            esac
          done < "$_rf"
          printf '%s\n' "''${_keep[@]}" > "$_rf"
          _args+=("$_a")
          ;;
        *) _args+=("$_a") ;;
      esac
    done
    set -- "''${_args[@]}"
  '';

  mkShimBin = binName: tool:
    buildPackages.writeShellScriptBin binName ''
      ${shimEnv}
      ${stripNoExceptions}
      exec ${toolchain.wasixcc}/bin/${tool} "$@"
    '';

  wasixShim = buildPackages.symlinkJoin {
    name = "wasix-cc${lib.optionalString (exceptions != null) "-${exceptions}"}${lib.optionalString pic "-pic"}";
    paths = [
      (mkShimBin "clang" "wasixcc")
      (mkShimBin "clang++" "wasix++")
    ];
    passthru.hardeningUnsupportedFlags = ["zerocallusedregs" "stackclashprotection"];
    passthru.isClang = true;
    # cc-wrapper injects -nostdlibinc for a clang cc, hiding the sysroot includes;
    # its isROCm branch is the one that suppresses that.
    passthru.isROCm = true;
  };

  wasixBintools = baseStdenv.cc.bintools.override {
    libc = null;
    noLibc = true;
    defaultHardeningFlags = []; # wasm rejects -fzero-call-used-regs / -fstack-clash-protection
  };
  # libc=null + noLibc skip libc/crt/sysroot injection while keeping the
  # buildInputs -> -I/-L propagation (an assert couples the cc and bintools pair);
  # libcxx=null keeps -cxx-isystem <nixpkgs libc++> out; the last two drop the
  # cross stdenv's inherited cc-flags (nixpkgs' compiler-rt, -fno-exceptions).
  wasixCC = baseStdenv.cc.override {
    cc = wasixShim;
    isClang = true; # wrapper arg; the base stdenv's cc is gcc
    libc = null;
    noLibc = true;
    bintools = wasixBintools;
    libcxx = null;
    extraBuildCommands = "";
    nixSupport = {};
  };

  # An isClang cc makes cmake scan its configure try-compiles with clang-scan-deps,
  # outside the shim and so without a sysroot; cmake reads the failed scan as a
  # failed probe ("No native support for std::atomic"). See WASIX-TODO.md. Both
  # doors, since scikit-build-core wheels invoke cmake themselves via CMAKE_ARGS.
  noCxxModuleScanHook =
    buildPackages.makeSetupHook {
      name = "wasix-cmake-no-cxx-module-scan";
    }
    (buildPackages.writeText "wasix-cmake-no-cxx-module-scan.sh" ''
      wasixDisableCxxModuleScan() {
        appendToVar cmakeFlags "-DCMAKE_CXX_SCAN_FOR_MODULES=OFF"
        export CMAKE_ARGS="-DCMAKE_CXX_SCAN_FOR_MODULES=OFF ''${CMAKE_ARGS-}"
      }
      preConfigureHooks+=(wasixDisableCxxModuleScan)
    '');
in
  # Every declared suite gets a check output holding its test tree, allowing
  # emulated-check.nix to run it without putting wasmer in the build closure.
  buildPackages.stdenvAdapters.overrideMkDerivationArgs checkOutputArgs
  (baseStdenv.override (_old: {
    cc = wasixCC;
    allowedRequisites = null;
    extraNativeBuildInputs = (_old.extraNativeBuildInputs or []) ++ [noCxxModuleScanHook];
  }))
