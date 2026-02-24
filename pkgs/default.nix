{ system, nixpkgs }:
let
  pkgs = import nixpkgs { inherit system; };
  toolchainPkgs = import ./toolchain { inherit pkgs; };

  toolchainEnv = rec {
    buildCc = "${pkgs.buildPackages.stdenv.cc}/bin/cc";
    host = "wasm32-wasix";
    crossSystem = {
      # Keep nixpkgs parser-compatible triple and pin WASIX tooling explicitly.
      config = "wasm32-unknown-wasi";
      useLLVM = true;
      isWasix = true;
    };

    toolchainEnv = ''
      export WASIXCC_LLVM_LOCATION="${toolchainPkgs.wasixLlvm}/bin"
      export WASIXCC_SYSROOT_PREFIX="${toolchainPkgs.wasixSysroot}"
      export WASIXCC_BINARYEN_LOCATION="${toolchainPkgs.binaryen}/bin"
      export WASIXCC_AUTOCONF_WORKAROUNDS=yes
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

    commonPreConfigure = ''
      export PATH="${toolchainPkgs.wasixcc}/bin:$PATH"
      ${toolchainEnv}
      ${ccEnv}
    '';
  };
  toolchain = toolchainPkgs // toolchainEnv;

  pkgsCross = import nixpkgs {
    inherit system;
    crossSystem = toolchainEnv.crossSystem;
  };

  libs = import ./libraries {
    nixpkgs = nixpkgs;
    inherit pkgsCross;
    inherit toolchain;
  };

  programs = import ./programs {
    nixpkgs = nixpkgs;
    inherit pkgs pkgsCross libs;
    inherit toolchain;
  };

  makeWasmerPackage = pkgs.callPackage ./wasmer/make-wasmer-package.nix { };
  makePlainWasmerPackage = pkgs.callPackage ./wasmer/make-plain-wasmer-package.nix { };

  nanoWasmer = pkgs.callPackage ./programs/nano/nanoWasmer.nix {
    inherit makeWasmerPackage;
    nano = programs.nano;
  };
  crabsayWasmer = pkgs.callPackage ./programs/crabsay/crabsayWasmer.nix {
    inherit makeWasmerPackage;
    crabsay = programs.crabsay;
  };

  cliPlatformWasmer = pkgs.callPackage ./wasmer/cli-platform.nix {
    inherit makePlainWasmerPackage;
  };

  wasmer = import ./wasmer {
    inherit (pkgs) lib;
    inherit pkgs nanoWasmer crabsayWasmer cliPlatformWasmer;
  };

  allPackages = libs // programs;

  allWasm = pkgs.runCommand "wasix-all-wasm" { } ''
    mkdir -p "$out/bin"
    ${pkgs.lib.concatMapStringsSep "\n" (name: ''
      if [ -d "${allPackages.${name}}/bin" ]; then
        ${pkgs.findutils}/bin/find "${allPackages.${name}}/bin" -maxdepth 1 -type f -name '*.wasm' \
          -exec ${pkgs.coreutils}/bin/cp -f '{}' "$out/bin/" \;
      fi
    '') (builtins.attrNames allPackages)}
  '';
in
{
  inherit pkgs pkgsCross toolchain libs programs wasmer allPackages allWasm;
}
