# The wasix cross stdenv: a nixpkgs cc-wrapper around wasixcc. Used as
# config.replaceCrossStdenv when importing nixpkgs for a wasix profile (see
# set/mk-pkgs.nix), so every package in the set builds with wasixcc. The
# profile (EH/PIC) is read from hostPlatform.wasmExceptions/wasmPic, carried
# by the crossSystem custom fields.
#
# Required cc-wrapper settings (base = the baseStdenv the replaceCrossStdenv
# hook hands us):
#   (1) cc = shim, NOT isClang: else the wrapper injects -nostdlibinc, hiding
#       the sysroot includes.
#   (2) libc=null/noLibc on cc AND bintools: skips libc/crt/sysroot injection,
#       keeps buildInputs -> -I/-L propagation (an assert couples the two).
#   (3) libcxx = null: else -cxx-isystem <nixpkgs libc++> leaks in.
#   (4) extraBuildCommands="" + nixSupport={}: drop the cross stdenv's inherited
#       cc-flags (nixpkgs' own compiler-rt, -fno-exceptions).
#   (5) defaultHardeningFlags=[] on bintools + hardeningUnsupportedFlags on the
#       shim: wasm rejects -fzero-call-used-regs / -fstack-clash-protection.
# The shim execs wasixcc/wasix++ with this profile's WASIXCC_* env.
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

  # Profile knobs + build-system workarounds from toolchain/env.nix (toolchain
  # locations aren't needed: the wasixcc bin wrappers bake them in).
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
