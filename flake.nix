{
  description = "WASIX package repository";

  nixConfig = {
    extra-substituters = ["https://nix-cache.wasix.org"];
    extra-trusted-public-keys = ["wasinix-1:jvsqbOJGsZxMvg97fuyNCWCc+t2nn6uHB47kQCGNmXI="];
  };

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    wasmer = {
      url = "git+https://github.com/wasmerio/wasmer";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # self.submodules = true;
  };

  outputs = {
    self,
    nixpkgs,
    wasmer,
    treefmt-nix,
    ...
  }: let
    system = "x86_64-linux";
    wasix = import ./pkgs {
      inherit system nixpkgs;
    };

    # Redesigned, from-source toolchain foundations (LLVM + libc + runtimes +
    # sysroot, built the upstream way). Now wired into the toolchain: pkgs/toolchain
    # consumes wasixNext.{llvmTree, sysroot} (the prebuilt downloads are retired).
    wasixNext = import ./pkgs/wasix-next {
      pkgs = wasix.pkgs;
      inherit nixpkgs system;
    };

    # End-to-end link + run tests, one per toolchain profile (= per ABI variant):
    # compile + link a C++ program with that profile's wasixcc, then run it under
    # wasmer. Exercises the from-source toolchain + sysroot through the real
    # consumer path.
    wasixLinkTests =
      builtins.mapAttrs (
        _name: toolchain:
          wasix.pkgs.callPackage ./pkgs/wasix-next/link-test.nix {
            wasmer = wasmer.packages.${system}.wasmer;
            inherit toolchain;
          }
      )
      wasix.toolchains;

    # Per-profile test of the first-class cross stdenv (cc-wrapper around
    # wasixcc): builds through a plain stdenv.mkDerivation (no env-injection),
    # exercising $CC/$CXX + buildInputs propagation, then runs under wasmer.
    wasixStdenvTests =
      builtins.mapAttrs (
        _name: toolchain:
          wasix.pkgs.callPackage ./pkgs/wasix-next/stdenv-test.nix {
            wasmer = wasmer.packages.${system}.wasmer;
            inherit toolchain;
          }
      )
      wasix.toolchains;

    treefmtEval = treefmt-nix.lib.evalModule wasix.pkgs {
      projectRootFile = "flake.nix";
      programs.alejandra.enable = true;
    };

    # Behavioural test suite + formatting check. Defined once, consumed by both
    # `checks` (nix flake check) and the `ci` build set below.
    flakeChecks =
      (import ./tests {
        inherit (wasix) pkgs;
        wasmerPkgs = wasix.wasmer.wrappedPackages;
        wasmer = wasmer.packages.${system}.wasmer;
      })
      // {
        treefmt = treefmtEval.config.build.check self;
      }
      # from-source wasix sysroot smoke tests, one per ABI variant
      // (wasix.pkgs.lib.mapAttrs' (name: t: wasix.pkgs.lib.nameValuePair "wasix-next-${name}" t) wasixNext.tests)
      # end-to-end link + run tests, one per toolchain profile
      // (wasix.pkgs.lib.mapAttrs' (name: t: wasix.pkgs.lib.nameValuePair "wasix-link-${name}" t) wasixLinkTests)
      # first-class stdenv (cc-wrapper around wasixcc) tests, one per profile
      // (wasix.pkgs.lib.mapAttrs' (name: t: wasix.pkgs.lib.nameValuePair "wasix-stdenv-${name}" t) wasixStdenvTests);
  in {
    formatter.${system} = treefmtEval.config.build.wrapper;

    wasix = {
      inherit (wasix) toolchains libraries programs defaultProfileName;
    };

    wasmer = wasix.wasmer.packages;

    legacyPackages.${system} = {
      pkgsCross = {
        wasix = wasix.pkgsCross;
      };

      # One derivation per entry for nix-eval-jobs/nix-fast-build to build
      # independently. Dotted keys, e.g. "libraries.exnrefEh.ncurses".
      ci = let
        inherit (wasix.pkgs) lib;
        defaultToolchain = wasix.toolchains.${wasix.defaultProfileName};
        derivationsOnly = lib.filterAttrs (_: lib.isDerivation);
        libraryJobs = lib.concatMapAttrs (
          profile:
            lib.mapAttrs' (name: drv: lib.nameValuePair "libraries.${profile}.${name}" drv)
        ) (lib.mapAttrs (_: derivationsOnly) wasix.libraries);
        programJobs = lib.mapAttrs' (name: drv: lib.nameValuePair "programs.${name}" drv) (derivationsOnly wasix.programs);
        wasmerJobs = lib.mapAttrs' (name: drv: lib.nameValuePair "wasmer.${name}" drv) (derivationsOnly wasix.wasmer.packages);
        toolchainJobs = {
          "toolchain.wasixcc" = defaultToolchain.wasixcc;
          "toolchain.cargo-wasix" = defaultToolchain.cargoWasix;
          # New from-source foundations (WIP):
          "toolchain.llvm-next.clang" = wasixNext.llvm.clang;
          "toolchain.llvm-next.lld" = wasixNext.llvm.lld;
          "toolchain.libc-next" = wasixNext.libc;
          "toolchain.compiler-rt-next" = wasixNext.compiler-rt;
          "toolchain.libcxx-next" = wasixNext.libcxx;
          "toolchain.sysroot-next" = wasixNext.sysroot;
          # The wasmer runtime itself (from the wasmer input).
          "wasmer-runtime" = wasmer.packages.${system}.wasmer;
        };
        checkJobs =
          lib.mapAttrs' (name: drv: lib.nameValuePair "checks.${name}" drv)
          (derivationsOnly flakeChecks);
      in
        libraryJobs // programJobs // wasmerJobs // toolchainJobs // checkJobs;
    };

    devShells.${system}.default = wasix.pkgs.mkShell {
      packages = [
        wasix.toolchains.${wasix.defaultProfileName}.wasixcc
        wasix.toolchains.${wasix.defaultProfileName}.cargoWasix
        wasix.libraries.${wasix.defaultProfileName}.ncurses
        wasix.pkgs.gnumake
        wasix.pkgs.pkg-config
        wasmer.packages.${system}.wasmer
      ];
      shellHook = ''
        ${wasix.toolchains.${wasix.defaultProfileName}.toolchainEnv}
        ${wasix.toolchains.${wasix.defaultProfileName}.ccEnv}
        echo "WASIX shell ready. Build with: nix build"
      '';
    };

    checks.${system} = flakeChecks;

    packages.${system} = {
      # Actual system packages.
      cargo-wasix = wasix.toolchains.${wasix.defaultProfileName}.cargoWasix;
      wasixcc = wasix.toolchains.${wasix.defaultProfileName}.wasixcc;

      # wasix outputs
      wasixAll = wasix.allWasm;
      wasmerAll = wasix.wasmer.allWasmer;
      default = wasix.allWasm;

      # WIP redesign foundations (build in isolation):
      #   nix build .#wasix-libc-next   (fast)
      #   nix build .#wasix-llvm-next   (from-source LLVM — slow)
      wasix-libc-next = wasixNext.libc;
      wasix-llvm-next = wasixNext.llvm.clang;
      # Runtimes built upstream-style (direct cmake of llvm-project driven by
      # wasix-libc's committed clang-wasix*.cmake_toolchain files):
      wasix-compiler-rt-next = wasixNext.compiler-rt;
      wasix-libcxx-next = wasixNext.libcxx;
      # The assembled multi-variant sysroot (drop-in for the download wasix-sysroot):
      wasix-sysroot-next = wasixNext.sysroot;
      # Smoke test of the default (off) variant's sysroot:
      wasix-test-next = wasixNext.tests.off;

      wasmer-bin = wasmer.packages.${system}.wasmer;

      # php83ZTS = wasix.libraries.${wasix.defaultProfileName}.php83ZTS;
      # php85ZTS = wasix.libraries.${wasix.defaultProfileName}.php85ZTS;
      # phpixPhp83 = wasix.programs.phpixPhp83;
      # phpixPhp85 = wasix.programs.phpixPhp85;
    };
  };
}
