# The wasix toolchain, built from source: LLVM fork, per-variant sysroot, and the
# wrappers driving them. `haskell` is a separate wasi toolchain; see haskell/.
{
  pkgs,
  ghcWasm,
}: let
  haskell = import ./haskell {inherit pkgs ghcWasm;};
  inherit (import ./llvm.nix {inherit pkgs;}) llvm llvmTree version;
  flang = import ./flang.nix {inherit pkgs;};
  flangCross = import ./flang-cross.nix {inherit (pkgs) lib;};
  sysroots = import ./sysroot {
    inherit pkgs llvm flang;
    llvmVersion = version;
  };
  inherit (sysroots) variants sysroot tests libc compiler-rt libcxx;

  flangRtByProfile = pkgs.lib.mapAttrs (_: v: v.flangRt) variants;

  # flang wrapped as a full compile+link driver, so a Fortran consumer can use it
  # like a normal cross compiler (cmake's probe succeeds, no FORCED vars).
  wasixflangByProfile =
    pkgs.lib.mapAttrs (
      name: prof:
        pkgs.callPackage ./wasixflang.nix {
          inherit flang wasixcc;
          flangRt = flangRtByProfile.${name};
          wasmExceptions = prof.wasmExceptions or "no";
          pic = prof.wasmPic or false;
        }
    )
    (import ../profiles.nix).profiles;
  openmpByProfile = pkgs.lib.mapAttrs (_: v: v.openmp) variants;

  wasixLlvm = llvmTree;
  wasixSysroot = sysroot;

  wasixRustToolchain = pkgs.callPackage ./rust/toolchain.nix {
    # The two wasix std targets use the EH and EH+PIC sysroots, as build-wasix.sh does.
    inherit wasixLlvm;
    wasixSysrootEh = variants.eh.sysroot;
    wasixSysrootEhpic = variants.ehpic.sysroot;
  };
  binaryen = pkgs.binaryen;
  # Crossable product recipe; the same definition is instantiated in every
  # WASIX profile before its target-specific overlay adapter is applied.
  anybuild = pkgs.anybuild;
  wasixcc = pkgs.callPackage ./wasixcc.nix {
    inherit wasixLlvm binaryen wasixSysroot;
  };
  cargoWasix = pkgs.callPackage ./rust/cargo-wasix.nix {
    inherit wasixRustToolchain wasixcc wasixLlvm binaryen wasixSysroot;
  };
in {
  # The wasix rustPlatform is assembled in pkgs/default.nix, where the pkgsCross
  # it needs is in scope.
  inherit anybuild wasixLlvm wasixSysroot wasixRustToolchain binaryen wasixcc cargoWasix;
  inherit llvm variants sysroot tests libc compiler-rt libcxx flang flangCross;
  # Internal inputs for pkgs/default.nix and the overlay. Profile-sensitive
  # outputs are public through toolchainByProfile, never as implicit defaults.
  inherit flangRtByProfile wasixflangByProfile openmpByProfile;
  inherit haskell;
}
