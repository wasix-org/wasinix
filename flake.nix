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
    ghc-wasm-meta = {
      # The official read-only mirror of gitlab.haskell.org/haskell-wasm:
      # same commits, narHash-verified, and CI already depends on github,
      # so a gitlab outage cannot take evaluation down with it.
      url = "github:haskell-wasm/ghc-wasm-meta";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    self,
    nixpkgs,
    wasmer,
    treefmt-nix,
    ghc-wasm-meta,
    ...
  }: let
    system = "x86_64-linux";
    projectApi = import ./pkgs/project/wasinix.nix {
      lib = nixpkgs.lib;
      ghcWasm = ghc-wasm-meta.packages.${system};
      wasmerPackage = wasmer.packages.${system}.wasmer;
      wasmerRevision = wasmer.shortRev or "dirty";
    };
    project = projectApi.mkProject {
      inherit system;
      importNixpkgs = args: import nixpkgs args;
      ci.sources = ["wasinix"];
      projectTests.treefmt = {
        source = "wasinix";
        check = _project: treefmtCheck;
      };
      repository = {
        source = "wasinix";
        root = self;
        revisionsFile = ./release-revisions.json;
      };
    };
    pkgs = project.internals.packageSets.nativeRaw;
    inherit (pkgs) lib;

    treefmtEval = treefmt-nix.lib.evalModule pkgs {
      projectRootFile = "flake.nix";
      # Captured tool output, compared byte for byte by the tests.
      settings.global.excludes = ["tools/wasinix/fixtures/golden/*"];
      programs = {
        alejandra.enable = true; # nix
        ruff-format.enable = true; # python
        # shell
        shfmt = {
          enable = true;
          indent_size = 2;
        };
        taplo.enable = true; # toml
        clang-format.enable = true; # c/c++
        # json stays out, as the only json in this repo is machine-generated
        prettier = {
          enable = true;
          includes = ["*.js" "*.yml" "*.yaml" "*.md"];
        };
        rustfmt.enable = true;
      };
    };
    treefmtCheck = treefmtEval.config.build.check self;

    wasinix = project.packages.native.wasinix;
    commandAliases = wasinix.commandAliases;
    commands =
      {
        default = wasinix;
        inherit wasinix;
      }
      // lib.genAttrs commandAliases (
        name:
          pkgs.writeShellApplication {
            inherit name;
            inheritPath = false;
            runtimeInputs = [wasinix];
            text = "exec wasinix ${name} \"$@\"";
          }
      );
    allCiCatalog = project.ci.catalog.jobs;
    jobsForSubjects = subjects:
      map (entry: entry.address) (lib.filter (entry:
        builtins.elem (entry.packageSubject or entry.address) subjects)
      (builtins.attrValues allCiCatalog));
    nativeSubjects = names: map (name: "packages.native.${name}") names;
    toolchainNames = [
      "cargo-wasix"
      "cargo-wasix-unwrapped"
      "wasix-flang"
      "wasix-llvm"
      "wasix-rust"
      "wasix-sysroot"
      "wasix-tinygo"
      "wasixcc"
      "wasixcc-unwrapped"
    ];
    ccNames = [
      "wasix-flang"
      "wasix-llvm"
      "wasix-sysroot"
      "wasix-tinygo"
      "wasixcc"
      "wasixcc-unwrapped"
    ];
    rustNames = ["cargo-wasix" "cargo-wasix-unwrapped" "wasix-rust"];
    selectorGroups = {
      toolchain = {
        jobs = jobsForSubjects (nativeSubjects toolchainNames);
        spotOwners = ["stdenv" "rustPlatform" "haskellPackages"];
      };
      cc = {
        jobs = jobsForSubjects (nativeSubjects ccNames);
        spotOwners = ["stdenv"];
      };
      rust = {
        jobs = jobsForSubjects (nativeSubjects rustNames);
        spotOwners = ["rustPlatform"];
      };
      haskell = {
        jobs = jobsForSubjects (map (profile: "packages.wasix.${profile}.pandoc") (builtins.attrNames project.packages.wasix));
        spotOwners = ["haskellPackages"];
      };
      emulated = {
        jobs = map (entry: entry.address) (lib.filter (entry: entry.testName or null == "captured") (builtins.attrValues allCiCatalog));
        spotOwners = [];
      };
    };
    systemProject =
      project
      // {
        ci =
          project.ci
          // {
            catalog =
              project.ci.catalog
              // {
                selectors.groups = selectorGroups;
              };
          };
      };
  in {
    lib = projectApi;
    formatter.${system} = treefmtEval.config.build.wrapper;
    apps.${system} =
      lib.mapAttrs (_: command: {
        type = "app";
        program = lib.getExe command;
      })
      commands;
    legacyPackages.${system} = systemProject;
    checks.${system} = systemProject.tests;
    packages.${system} = {
      default = wasinix;
      inherit wasinix;
    };
    devShells.${system}.default = pkgs.mkShell {
      packages = [
        wasinix
        project.packages.native.cargo-wasix
        project.packages.native.wasixcc
        project.packages.preferred.ncurses
        pkgs.gnumake
        pkgs.pkg-config
        project.packages.native.wasmer
        pkgs.nix-eval-jobs
        pkgs.nixVersions.latest
      ];
    };
  };
}
