{
  pkgs,
  toolchainPkgs,
  pkgsCross,
  crossSystem,
}: {
  name,
  wasmExceptions ? null,
  pic ? false,
}: let
  lib = pkgs.lib;
  buildCc = "${pkgs.buildPackages.stdenv.cc}/bin/cc";
  host = "wasm32-wasix";
  profileEnv = lib.concatStringsSep "\n" (
    lib.optional (wasmExceptions != null)
    "export WASIXCC_WASM_EXCEPTIONS=${lib.escapeShellArg wasmExceptions}"
    ++ [
      "export WASIXCC_PIC=${
        if pic
        then "yes"
        else "no"
      }"
    ]
  );
  toolchainEnv = ''
    export WASIXCC_LLVM_LOCATION="${toolchainPkgs.wasixLlvm}/bin"
    export WASIXCC_SYSROOT_PREFIX="${toolchainPkgs.wasixSysroot}"
    export WASIXCC_BINARYEN_LOCATION="${toolchainPkgs.binaryen}/bin"
    export WASIXCC_AUTOCONF_WORKAROUNDS=yes
    ${profileEnv}
  '';
  ccEnv = ''
    export CC=wasixcc
    export CXX=wasix++
    export LD=wasixld
    export AR=wasixar
    export NM=wasixnm
    export RANLIB=wasixranlib
    export WASIXCC_RUN_WASM_OPT=no
  '';

  # ── First-class cross stdenv: a nixpkgs cc-wrapper around wasixcc ───────────
  # This is the modern alternative to the `commonPreConfigure` env-injection
  # above: packages built with `stdenv` get a real `$CC`/`$CXX` plus automatic
  # buildInputs → -I/-L propagation, instead of exporting CC=wasixcc by hand.
  #
  # `wasixShim` presents wasixcc as a clang-shaped front end (bin/clang,
  # bin/clang++) carrying this profile's WASIXCC_* knobs. We deliberately do NOT
  # mark it isClang — see knob (1). wasixcc itself is a complete driver (it wires
  # libc/libc++/compiler-rt/sysroot/EH/PIC), so the wrapper must inject *nothing*
  # compiler-specific; we strip every flag source the cc-wrapper would normally
  # add for a bare clang. The five non-obvious knobs, each load-bearing:
  #   (1) NOT isClang        — else the wrapper adds `-nostdlibinc`, which hides
  #                            the sysroot includes (`stdio.h not found`).
  #   (2) libc=null/noLibc   — on BOTH cc-wrapper and bintools (an assert couples
  #                            them); skips libc/crt/sysroot injection, keeps the
  #                            buildInputs propagation hook.
  #   (3) libcxx=null        — else `-cxx-isystem <nixpkgs libc++>` leaks in (and
  #                            wasixcc can't parse its separated-arg form).
  #   (4) extraBuildCommands="" + nixSupport={}
  #                          — drop the cross stdenv's inherited cc-flags, which
  #                            point at nixpkgs' OWN compiler-rt and add
  #                            `-fno-exceptions` (would break the EH variants).
  #   (5) defaultHardeningFlags=[] (on bintools)
  #                          — nixpkgs' default hardening includes flags clang
  #                            rejects for wasm (`-fzero-call-used-regs`,
  #                            `-fstack-clash-protection`); wasm is sandboxed so
  #                            they're moot anyway.
  # WASIXCC_DISCARD_UNSUPPORTED_FLAGS=yes lets wasixcc drop GNU-ld flags the
  # cc-wrapper forwards via NIX_LDFLAGS that wasm-ld can't parse (e.g. zlib's
  # `--undefined-version`).
  wasixShimEnv = lib.concatStringsSep "\n" (
    lib.optional (wasmExceptions != null)
    "export WASIXCC_WASM_EXCEPTIONS=${lib.escapeShellArg wasmExceptions}"
    ++ [
      "export WASIXCC_PIC=${
        if pic
        then "yes"
        else "no"
      }"
      "export WASIXCC_RUN_WASM_OPT=no"
      "export WASIXCC_AUTOCONF_WORKAROUNDS=yes"
      "export WASIXCC_DISCARD_UNSUPPORTED_FLAGS=yes"
    ]
  );
  mkShimBin = binName: tool:
    pkgs.writeShellScriptBin binName ''
      ${wasixShimEnv}
      exec ${toolchainPkgs.wasixcc}/bin/${tool} "$@"
    '';
  wasixShim = pkgs.symlinkJoin {
    name = "wasix-cc-${name}";
    paths = [
      (mkShimBin "clang" "wasixcc")
      (mkShimBin "clang++" "wasix++")
    ];
    # clang rejects these hardening flags for the wasm target. nixpkgs' wasm
    # exclusion list (cc-wrapper) only drops stackprotector/fortify/pie/pic, so
    # declare the rest unsupported here — this strips them from the active set
    # *unconditionally* (defaultHardeningFlags=[] only changes the baseline; a
    # package whose configure re-enables hardening — e.g. sqlite's autosetup
    # conftest — would still pull -fzero-call-used-regs without this).
    passthru.hardeningUnsupportedFlags = ["zerocallusedregs" "stackclashprotection"];
  };
  wasixBintools = pkgsCross.stdenv.cc.bintools.override {
    libc = null;
    noLibc = true;
    defaultHardeningFlags = [];
  };
  wasixCC = pkgsCross.stdenv.cc.override {
    cc = wasixShim;
    libc = null;
    noLibc = true;
    bintools = wasixBintools;
    libcxx = null;
    extraBuildCommands = "";
    nixSupport = {};
  };
  stdenv = pkgsCross.overrideCC pkgsCross.stdenv wasixCC;
in
  toolchainPkgs
  // {
    profileName = name;
    inherit buildCc host crossSystem wasmExceptions pic toolchainEnv ccEnv stdenv;

    commonPreConfigure = ''
      export PATH="${toolchainPkgs.wasixcc}/bin:$PATH"
      ${toolchainEnv}
      ${ccEnv}
    '';
  }
