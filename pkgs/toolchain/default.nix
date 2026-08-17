# The wasix toolchain, built from source: LLVM fork, per-variant sysroot, and the
# wrappers driving them. `haskell` is a separate wasi toolchain; see haskell/.
{
  pkgs,
  ghcWasm,
}: let
  haskell = import ./haskell {inherit pkgs ghcWasm;};
  inherit (pkgs.wasix-llvm.passthru) llvm llvmVersion monorepoSrc version;
  llvmTree = pkgs.wasix-llvm;
  llvmMonorepoSrc = monorepoSrc;
  flang = pkgs.wasix-flang;
  flangCross = import ./flang-cross.nix {inherit (pkgs) lib;};
  sysroots = pkgs.wasix-sysroot.passthru // {sysroot = pkgs.wasix-sysroot;};
  inherit
    (sysroots)
    variants
    sysroot
    tests
    libc
    compiler-rt
    libcxx
    ;

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

  crateEdits =
    import ../lib/crate-edits.nix {
      inherit pkgs;
      pins = builtins.fromJSON (builtins.readFile ../cargo-registry/crates.json);
    }
    ../lib/wasix-crate-patches;
  vendorPatches = import ../lib/patch-rust-vendor.nix {
    inherit (pkgs) lib;
    hostPkgs = pkgs;
    inherit crateEdits;
  };

  wasixLlvm = llvmTree;
  wasixSysroot = sysroot;

  wasixRustToolchain = pkgs.wasix-rust;
  wasixTinyGo = pkgs.wasix-tinygo;
  wasixHostedRustToolchain = wasixRustToolchain.override {
    hostedOnWasix = true;
  };
  binaryen = pkgs.binaryen;
  wasixcc = pkgs.wasixcc;
  cargoWasix = pkgs.cargo-wasix;
in {
  # The wasix rustPlatform is assembled in pkgs/default.nix, where the pkgsCross
  # it needs is in scope.
  inherit
    wasixLlvm
    wasixSysroot
    wasixRustToolchain
    wasixTinyGo
    wasixHostedRustToolchain
    binaryen
    wasixcc
    cargoWasix
    ;
  inherit
    llvm
    llvmMonorepoSrc
    llvmVersion
    variants
    sysroot
    tests
    libc
    compiler-rt
    libcxx
    flang
    flangCross
    ;
  # Internal inputs for pkgs/default.nix and the overlay. Profile-sensitive
  # outputs are public through toolchainByProfile, never as implicit defaults.
  inherit flangRtByProfile wasixflangByProfile openmpByProfile;
  inherit haskell;
}
