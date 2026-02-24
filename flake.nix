{
  description = "WASIX package repository";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { nixpkgs, ... }:
    let
      system = "x86_64-linux";
      wasix = import ./pkgs {
        inherit system nixpkgs;
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
          wasix.toolchain.cargoWasix
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
          inherit (wasix.toolchain) wasixcc;
          cargo-wasix = wasix.toolchain.cargoWasix;
          wasix-rust-toolchain = wasix.toolchain.wasixRustToolchain;
          inherit (wasix.libs) ncurses;
          inherit (wasix.programs) nano crabsay;
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
