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
    crane.follows = "wasmer/crane";
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
    crane,
    treefmt-nix,
    ghc-wasm-meta,
    ...
  }: let
    system = "x86_64-linux";
    projectApi = import ./pkgs/project/wasinix.nix {
      inherit (nixpkgs) lib;
      ghcWasm = ghc-wasm-meta.packages.${system};
      wasinixFlake = self;
      wasinixCrane = crane;
      wasmerPackage = wasmer.packages.${system}.wasmer;
      wasmerRevision = wasmer.shortRev or "dirty";
    };
    repositorySource = let
      source = builtins.path {
        path = self;
        name = "source";
        filter = path: _type: baseNameOf path != ".git";
      };
    in
      if builtins.pathExists (source + "/.git")
      then throw "repository source contains Git metadata"
      else source;
    repositoryCheckNames = ["deadnix" "nil" "nixf" "project-api" "statix" "treefmt"];
    testLibFor = checkedProject: let
      nativePkgs = checkedProject.internals.packageSets.nativeRaw;
    in
      import ./pkgs/wasmer/test-lib.nix {
        pkgs = nativePkgs;
        wasmer = checkedProject.packages.native.wasmer;
      };
    project = projectApi.mkProject {
      inherit system;
      importNixpkgs = args: import nixpkgs args;
      ci.sources = ["wasinix"];
      projectTests =
        {
          consumer-project = {
            source = "wasinix";
            check = _project: consumerProjectCheck;
          };
          asyncify-eh = {
            source = "wasinix";
            check = checkedProject: let
              nativePkgs = checkedProject.internals.packageSets.nativeRaw;
              toolchain = import ./pkgs/toolchain {pkgs = nativePkgs;};
              testLib = testLibFor checkedProject;
              devEnvFor = import ./pkgs/toolchain/dev-env.nix {
                pkgs = nativePkgs;
                inherit toolchain;
              };
            in
              nativePkgs.callPackage ./pkgs/toolchain/tests/asyncify-eh-test.nix {
                inherit testLib;
                toolchain = devEnvFor {wasmExceptions = "yes";};
              };
          };
          host-shell-flags = {
            source = "wasinix";
            check = checkedProject: let
              nativePkgs = checkedProject.internals.packageSets.nativeRaw;
            in
              nativePkgs.callPackage ./pkgs/wasmer/tests/flags.nix {
                testLib = testLibFor checkedProject;
              };
          };
        }
        // builtins.listToAttrs (map (name: {
            inherit name;
            value = {
              source = "wasinix";
              check = _project: repositoryChecks.${name};
            };
          })
          repositoryCheckNames);
      repository = {
        source = "wasinix";
        root = repositorySource;
        revisionsFile = ./release-revisions.json;
        publication = {
          cargo.registry = "https://cargo-registry.wasix.org";
          python = {
            registry = "wasmer.io";
            appDirectory = "pkgs/python-registry";
          };
          wasmer.registry = "wasmer.io";
          provenance = {
            flake = "github:wasix-org/wasinix";
            repository = "wasix-org/wasinix";
          };
        };
      };
    };
    pkgs = project.internals.packageSets.nativeRaw;
    inherit (pkgs) lib;

    treefmtFor = module:
      treefmt-nix.lib.evalModule pkgs (lib.recursiveUpdate {
          projectRootFile = "flake.nix";
          # Captured tool output, compared byte for byte by the tests.
          settings.global.excludes = ["tools/wasinix/fixtures/golden/*"];
        }
        module);
    treefmtEval = treefmtFor {
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
    treefmtCheck = treefmtEval.config.build.check repositorySource;
    nixLintChecks = lib.mapAttrs (_name: module: (treefmtFor module).config.build.check repositorySource) {
      deadnix.programs.deadnix = {
        enable = true;
        no-lambda-pattern-names = true;
      };
      nil.settings.formatter.nil = {
        command = lib.getExe pkgs.nil;
        options = ["diagnostics" "--deny-warnings"];
        includes = ["*.nix"];
      };
      nixf = {
        programs.nixf-diagnose = {
          enable = true;
          autoFix = false;
        };
        settings.formatter.nixf-diagnose.excludes = ["spot.nix"];
      };
      statix = {
        programs.statix.enable = true;
        settings.formatter.statix = {
          command = lib.mkForce (pkgs.writeShellApplication {
            name = "statix-check";
            runtimeInputs = [pkgs.statix];
            text = ''
              status=0
              diagnostics="$(statix check --format errfmt . 2>&1)" || status=$?
              if [[ -n "$diagnostics" ]]; then
                printf '%s\n' "$diagnostics" >&2
              fi
              if (( status != 0 )) || [[ -n "$diagnostics" ]]; then
                exit 1
              fi
            '';
          });
          includes = lib.mkForce ["flake.nix"];
        };
      };
    };
    projectApiTests = import ./pkgs/project/tests.nix {inherit lib;};
    failedProjectApiTests = lib.attrNames (lib.filterAttrs (_: test: test.expr != test.expected) projectApiTests);
    requiredProjectApi = ["appsForProject" "cliForProject" "extendPackage" "loadPackageOverlays" "mkEmptyProject" "mkProject"];
    missingProjectApi = lib.subtractLists (builtins.attrNames projectApi) requiredProjectApi;
    projectApiCheck =
      lib.throwIf (missingProjectApi != [])
      "project API is missing: ${lib.concatStringsSep ", " missingProjectApi}"
      (lib.throwIf (failedProjectApiTests != [])
        "project API tests failed: ${lib.concatStringsSep ", " failedProjectApiTests}"
        (pkgs.runCommand "wasinix-project-api-tests" {} ''
          touch "$out"
        ''));
    consumerProjectCheck = import ./pkgs/project/tests/consumer-flake/check.nix {
      inherit pkgs projectApi system;
      importNixpkgs = args: import nixpkgs args;
      root = ./pkgs/project/tests/consumer-flake;
    };
    repositoryChecks =
      nixLintChecks
      // {
        treefmt = treefmtCheck;
        project-api = projectApiCheck;
      };
    checkedRepositoryChecks =
      lib.throwIf (builtins.attrNames repositoryChecks != repositoryCheckNames)
      "repository checks do not match repositoryCheckNames"
      repositoryChecks;

    projectAttr = "legacyPackages.${system}";
    wasinixCore = project.packages.native.wasinix;
    wasinix = projectApi.cliForProject {inherit project projectAttr;};
    wasinixApps = projectApi.appsForProject {inherit project projectAttr;};
    wasinixCapabilities = (import ./pkgs/project/apps.nix {inherit lib project projectAttr;}).capabilities;
  in {
    lib = projectApi;
    formatter.${system} = treefmtEval.config.build.wrapper;
    apps.${system} = wasinixApps;
    legacyPackages.${system} = project;
    checks.${system} = checkedRepositoryChecks;
    packages.${system} = {
      default = wasinix;
      inherit wasinix;
      wasinix-core = wasinixCore;
      wasinix-capability-aws = wasinixCapabilities.aws;
      wasinix-capability-python = wasinixCapabilities.python;
      wasinix-capability-python-index = wasinixCapabilities.python-index;
      wasinix-capability-rclone = wasinixCapabilities.rclone;
      wasinix-capability-wasmer = wasinixCapabilities.wasmer;
    };
    devShells.${system} = {
      default = pkgs.mkShell {
        packages = [
          wasinix
          pkgs.nixVersions.latest
          project.packages.native.wasmer
        ];
      };
      building = pkgs.mkShell {
        packages = [
          wasinix
          pkgs.nixVersions.latest
          project.packages.native.wasmer

          project.packages.native.cargo-wasix
          project.packages.native.wasixcc

          project.packages.wasix.preferred.ncurses

          pkgs.gnumake
          pkgs.pkg-config
        ];
      };
    };
  };
}
