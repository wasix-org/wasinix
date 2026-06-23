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

    treefmtEval = treefmt-nix.lib.evalModule wasix.pkgs {
      projectRootFile = "flake.nix";
      programs.alejandra.enable = true;
    };
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
        derivationsOnly = lib.filterAttrs (_: lib.isDerivation);
        libraryJobs = lib.concatMapAttrs (
          profile:
            lib.mapAttrs' (name: drv: lib.nameValuePair "libraries.${profile}.${name}" drv)
        ) (lib.mapAttrs (_: derivationsOnly) wasix.libraries);
        programJobs = lib.mapAttrs' (name: drv: lib.nameValuePair "programs.${name}" drv) (derivationsOnly wasix.programs);
        wasmerJobs = lib.mapAttrs' (name: drv: lib.nameValuePair "wasmer.${name}" drv) (derivationsOnly wasix.wasmer.packages);
      in
        libraryJobs // programJobs // wasmerJobs;
    };

    devShells.${system}.default = wasix.pkgs.mkShell {
      packages = [
        wasix.toolchains.${wasix.defaultProfileName}.wasixcc
        wasix.toolchains.${wasix.defaultProfileName}.cargoWasix
        wasix.libraries.${wasix.defaultProfileName}.ncurses
        wasix.pkgs.gnumake
        wasix.pkgs.pkg-config
      ];
      shellHook = ''
        ${wasix.toolchains.${wasix.defaultProfileName}.toolchainEnv}
        ${wasix.toolchains.${wasix.defaultProfileName}.ccEnv}
        echo "WASIX shell ready. Build with: nix build"
      '';
    };

    checks.${system} =
      (import ./tests {
        inherit (wasix) pkgs;
        wasmerPkgs = wasix.wasmer.wrappedPackages;
        wasmer = wasmer.packages.${system}.wasmer;
      })
      // {
        treefmt = treefmtEval.config.build.check self;
      };

    packages.${system} = {
      # Actual system packages.
      cargo-wasix = wasix.toolchains.${wasix.defaultProfileName}.cargoWasix;
      wasixcc = wasix.toolchains.${wasix.defaultProfileName}.wasixcc;

      # wasix outputs
      wasixAll = wasix.allWasm;
      wasmerAll = wasix.wasmer.allWasmer;
      default = wasix.allWasm;

      # php83ZTS = wasix.libraries.${wasix.defaultProfileName}.php83ZTS;
      # php85ZTS = wasix.libraries.${wasix.defaultProfileName}.php85ZTS;
      # phpixPhp83 = wasix.programs.phpixPhp83;
      # phpixPhp85 = wasix.programs.phpixPhp85;
    };
  };
}
