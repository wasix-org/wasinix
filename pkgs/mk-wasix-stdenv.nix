# The first-class wasix cross stdenv: a nixpkgs cc-wrapper around wasixcc.
#
# Used as `config.replaceCrossStdenv` when importing nixpkgs for a wasix profile
# (see mk-wasix-pkgs.nix), so EVERY package in that set builds with wasixcc and
# its dependencies auto-thread within the profile. The profile (EH/PIC) is read
# from the platform record (hostPlatform.wasmExceptions/wasmPic), which the
# crossSystem custom fields carry.
#
# The six load-bearing knobs (the base is the `baseStdenv` the replaceCrossStdenv
# hook hands us):
#   (1) cc = shim, NOT isClang   — else the wrapper injects -nostdlibinc, hiding
#                                  the sysroot includes.
#   (2) libc=null/noLibc on cc AND bintools — skip libc/crt/sysroot injection,
#       keep buildInputs -> -I/-L propagation (an assert couples the two).
#   (3) libcxx = null            — else -cxx-isystem <nixpkgs libc++> leaks in.
#   (4) extraBuildCommands="" + nixSupport={} — drop the cross stdenv's inherited
#       cc-flags (nixpkgs' own compiler-rt, -fno-exceptions).
#   (5) defaultHardeningFlags=[] on bintools + hardeningUnsupportedFlags on the
#       shim — wasm rejects -fzero-call-used-regs / -fstack-clash-protection.
# The shim execs wasixcc/wasix++ with this profile's WASIXCC_* knobs.
{
  lib,
  foundation,
}: {
  buildPackages,
  baseStdenv,
}: let
  hp = baseStdenv.hostPlatform;
  exceptions = hp.wasmExceptions or null;
  pic = hp.wasmPic or false;

  shimEnv = lib.concatStringsSep "\n" (
    lib.optional (exceptions != null)
    "export WASIXCC_WASM_EXCEPTIONS=${lib.escapeShellArg exceptions}"
    ++ [
      "export WASIXCC_PIC=${
        if pic
        then "yes"
        else "no"
      }"
      "export WASIXCC_AUTOCONF_WORKAROUNDS=yes"
      "export WASIXCC_DISCARD_UNSUPPORTED_FLAGS=yes"
    ]
  );

  mkShimBin = binName: tool:
    buildPackages.writeShellScriptBin binName ''
      ${shimEnv}
      exec ${foundation.wasixcc}/bin/${tool} "$@"
    '';

  wasixShim = buildPackages.symlinkJoin {
    name = "wasix-cc${lib.optionalString (exceptions != null) "-${exceptions}"}${lib.optionalString pic "-pic"}";
    paths = [
      (mkShimBin "clang" "wasixcc")
      (mkShimBin "clang++" "wasix++")
    ];
    passthru.hardeningUnsupportedFlags = ["zerocallusedregs" "stackclashprotection"];
  };

  wasixBintools = baseStdenv.cc.bintools.override {
    libc = null;
    noLibc = true;
    defaultHardeningFlags = [];
  };
  wasixCC = baseStdenv.cc.override {
    cc = wasixShim;
    libc = null;
    noLibc = true;
    bintools = wasixBintools;
    libcxx = null;
    extraBuildCommands = "";
    nixSupport = {};
  };
in
  # overrideCC-equivalent inside the replaceCrossStdenv hook (we have no pkgsCross
  # handle here); allowedRequisites=null mirrors what overrideCC does.
  baseStdenv.override (_old: {
    cc = wasixCC;
    allowedRequisites = null;
  })
