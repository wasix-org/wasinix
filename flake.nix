{
  description = "WASIX package repository";

  inputs = {
    wasixcc.url = "github:wasix-org/wasixcc?ref=nix-flake";
    nixpkgs.follows = "wasixcc/nixpkgs";
  };

  outputs = { nixpkgs, wasixcc, ... }:
    let
      system = "x86_64-linux";
      wasix = import ./pkgs {
        inherit system nixpkgs wasixcc;
      };

    in {
      legacyPackages.${system} = {
        pkgsCross = {
          wasix = wasix.pkgsCross;
        };
      };

      devShells.${system}.default = wasix.pkgs.mkShell {
        packages = [
          wasix.toolchain.wasixcc
          wasix.libs.ncurses
          wasix.pkgs.gnumake
          wasix.pkgs.pkg-config
        ];
        shellHook = ''
          ${wasix.toolchain.toolchainEnv}
          ${wasix.toolchain.ccEnv}
          echo "WASIX shell ready. Build with: nix build"
        '';
      };

      packages.${system} =
        {
          # Individual plain packages
          inherit (wasix.libs) ncurses;
          inherit (wasix.programs) nano;
        }
        // wasix.wasmer.packages
        // {
          # Aggregate package with all discovered WASM binaries.
          all = wasix.allWasm;
          allWasmer = wasix.wasmer.allWasmer;
          default = wasix.allWasm;
        };
    };
}
