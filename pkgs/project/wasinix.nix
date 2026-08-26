{
  lib,
  ghcWasm,
  wasinixFlake ? null,
  wasinixCrane ? null,
  wasmerPackage ? null,
  wasmerRevision ? "dirty",
}: let
  profiles = import ./profiles.nix;
  compatibility = import ../lib {inherit lib;};
  projectLib = import ./lib.nix {inherit lib;};
  repairPythonPackage = import ../python/lib/repair.nix {
    inherit lib;
    inherit (projectLib) mergeScript;
  };
  constructProject = includeWasinix: {
    system,
    importNixpkgs,
    extensions ? [],
    projectionRules ? {},
    projectTests ? {},
    repository ? null,
    ci ? {},
  }: let
    constructor =
      if includeWasinix
      then projectApi.mkProject
      else projectApi.mkEmptyProject;
    baseProject = constructor {
      inherit system importNixpkgs extensions projectionRules projectTests ci;
    };
    repositoryInfo =
      if repository == null
      then null
      else
        import ./repository.nix ({
            inherit lib;
            project = baseProject;
          }
          // repository);
    repositoryProject =
      if repositoryInfo == null
      then baseProject
      else
        baseProject
        // {
          internals = baseProject.internals // {repository = repositoryInfo;};
        };
    builtInSelectorGroups =
      if includeWasinix
      then
        import ./selectors.nix {
          inherit lib;
          project = repositoryProject;
        }
      else {};
    duplicateSelectorGroups = lib.intersectLists (lib.attrNames builtInSelectorGroups) (lib.attrNames (ci.groups or {}));
    project =
      lib.throwIf (duplicateSelectorGroups != [])
      "CI selector group(s) duplicate Wasinix defaults: ${lib.concatStringsSep ", " duplicateSelectorGroups}"
      (repositoryProject
        // {
          ci =
            repositoryProject.ci
            // {
              catalog =
                repositoryProject.ci.catalog
                // {
                  selectors =
                    repositoryProject.ci.catalog.selectors
                    // {
                      groups = builtInSelectorGroups // (ci.groups or {});
                    };
                };
            };
        });

    constructionFor = nativePkgs: let
      rawWasm = import ../runners/raw-wasm.nix {pkgs = nativePkgs;};
      runtime = nativePkgs.wasmer;
      referenceScanner = nativePkgs.callPackage ../lib/check-reference-scanner.nix {};
      helpers = import ../lib {
        inherit lib referenceScanner;
        snapshotZstd = nativePkgs.zstd;
      };
      toolchain = import ../toolchain {pkgs = nativePkgs;};
      rustCrossPkgs = importNixpkgs {
        localSystem = {inherit system;};
        crossSystem = {
          config = "wasm32-unknown-wasi";
          useLLVM = true;
          isWasix = true;
          rust.rustcTarget = "wasm32-wasmer-wasi";
        };
        config.allowUnsupportedSystem = true;
        overlays = [];
      };
      crateEdits =
        import ../lib/crate-edits.nix {
          pkgs = nativePkgs;
          pins = builtins.fromJSON (builtins.readFile ../cargo-registry/crates.json);
        }
        ../lib/wasix-crate-patches;
      wasixRustPlatform = import ../set/rust-platform.nix {
        inherit lib crateEdits;
        pkgsCross = rustCrossPkgs;
        inherit (nativePkgs) cargo;
        inherit (toolchain) wasixRustToolchain wasixcc cargoWasix binaryen;
      };
      mkWasixStdenv = import ../set/stdenv.nix {
        inherit lib toolchain referenceScanner;
        snapshotZstd = nativePkgs.zstd;
      };
      wasixInfrastructureOverlay = import ../set/wasix-overlay.nix {
        inherit toolchain wasixRustPlatform;
        wasixRunStub = rawWasm.unbound;
      };
      wasmerDependencies = import ../wasmer/dependencies.nix {inherit lib;};
      makeWasmerPackage = nativePkgs.callPackage ../wasmer/make-wasmer-package.nix {
        self = makeWasmerPackage;
        wasmer = runtime;
        inherit wasmerDependencies;
        inherit (helpers) posOf;
      };
      inherit ((import ../wasmer/ident.nix {inherit lib;})) webcIdent;
      wasmerProjection = import ../artifacts/wasmer.nix {
        inherit lib makeWasmerPackage webcIdent;
      };
      testLib = import ../wasmer/test-lib.nix {
        pkgs = nativePkgs;
        wasmer = runtime;
      };
      wasixRun = {
        stub = rawWasm.unbound;
        run = rawWasm.withRuntime runtime;
      };
      emulatedChecks = import ../checks/emulated.nix {
        inherit lib wasixRun;
        pkgs = nativePkgs;
      };
      abiCheck = nativePkgs.callPackage ../toolchain/tests/abi-check.nix {
        inherit (toolchain) wasixLlvm binaryen;
      };
      linkCheck = import ../checks/link-runner.nix {
        inherit lib wasixRun;
        pkgs = nativePkgs;
        inherit helpers;
      };
      mkTestGroup = import ../lib/test-group.nix {
        inherit lib;
        pkgs = nativePkgs;
        inherit (helpers) posOf;
      };
      mkPythonWheels = args:
        import ../python/wheels/project.nix ({
            inherit lib emulatedChecks harnesses mkTestGroup;
            pkgs = nativePkgs;
            inherit (helpers.checkOutput) installCheckOutputArgsIf;
          }
          // args);
      mkPythonRegistry = args:
        import ../python-registry ({
            inherit lib mkTestGroup testLib;
            pkgs = nativePkgs;
          }
          // args);
      mkCargoRegistry = import ../cargo-registry {
        inherit lib crateEdits mkTestGroup;
        cargoRegistryWire = nativePkgs."cargo-registry-wire";
        pkgs = nativePkgs;
      };
      harnesses =
        import ../harnesses {
          inherit lib makeWasmerPackage testLib;
          pkgs = nativePkgs;
          wasmer = runtime;
        }
        // {
          packageCommand = {
            package,
            name ? (webcIdent package).name,
            entrypoint ? (package.passthru.wasmer or {}).entrypoint or name,
          }: {
            inherit name entrypoint;
            artifact = (makeWasmerPackage {inherit package;}).webc;
          };
          packageCommands = package: let
            artifact = (makeWasmerPackage {inherit package;}).webc;
          in
            wasmerProjection.commandsForPackage {
              inherit artifact package;
              label = package.pname or package.name;
            };
          capturedSuite = emulatedChecks.checkFor;
        };
    in {
      inherit abiCheck emulatedChecks harnesses linkCheck makeWasmerPackage mkCargoRegistry mkPythonRegistry mkPythonWheels mkWasixStdenv testLib wasixInfrastructureOverlay webcIdent;
      inherit (toolchain) haskell;
      runners.rawWasm = {
        inherit (rawWasm) unbound;
        withRuntime = rawWasm.withRuntime runtime;
      };
    };
    builtInExtension = import ./extension.nix {
      inherit (projectApi) loadPackageOverlays;
    };
    historyLib = import ./history.nix {
      inherit lib projectLib;
    };
    wasinixProjectionRules = {
      historyVersions = {
        namespaces = ["versions"];
        entry = {
          entry,
          instantiateVersions,
          ...
        }: {
          versions = instantiateVersions entry;
        };
      };
      cargoRegistryArtifact = {
        entry,
        packageSets,
        ...
      }: ((import ../artifacts/cargo.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) mkCargoRegistry;
        })
          .registryArtifact
        {inherit entry;});
      wasmerArtifacts = {
        entry,
        packages,
        packageSets,
        ...
      }: ((import ../artifacts/wasmer.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) makeWasmerPackage webcIdent;
        })
          .wasmerArtifacts
        {inherit entry packages;});
      wasmerCommands = {
        entry,
        packages,
        packageSets,
        ...
      }: ((import ../artifacts/wasmer.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) makeWasmerPackage webcIdent;
        })
          .wasmerCommands
        {inherit entry packages;});
      inherit
        (import ../checks/behavior.nix {
          inherit lib;
          projectLib = import ./lib.nix {inherit lib;};
        })
        packageBehavior
        packagedBehavior
        ;
      pythonWheelArtifacts = {
        entry,
        packages,
        packageSets,
        pythonVariants,
        ...
      }: ((import ../artifacts/python.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) mkPythonRegistry mkPythonWheels;
        })
          .wheelArtifacts
        {inherit entry packages packageSets pythonVariants;});
      pythonRegistryArtifact = {
        source = "wasinix";
        namespaces = ["artifacts"];
        project = {
          catalog,
          packages,
          packageSets,
          pythonVariants,
          ...
        }: ((import ../artifacts/python.nix {
            inherit lib;
            inherit ((constructionFor packageSets.native)) mkPythonRegistry mkPythonWheels;
          })
            .registryArtifact
          {inherit catalog packages packageSets pythonVariants;});
      };
      inherit
        (import ../artifacts/python.nix {
          inherit lib;
          mkPythonRegistry = null;
          mkPythonWheels = null;
        })
        artifactTests
        ;
      packageLink = {
        entry,
        packages,
        packageSets,
        ...
      }: ((import ../checks/link.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) linkCheck;
        })
          .packageLink
        {inherit entry packages;});
      packageAbi = {
        entry,
        packageSets,
        profileSets,
        ...
      }: ((import ../checks/abi.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) abiCheck;
        })
          .packageAbi
        {inherit entry profileSets;});
      capturedSuite = {
        entry,
        packageSets,
        ...
      }: ((import ../checks/captured.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) emulatedChecks;
        })
          .capturedSuite
        {inherit entry;});
    };
    projectApi = import ./default.nix {
      inherit lib profiles builtInExtension;
      inherit repairPythonPackage;
      projectionRules = wasinixProjectionRules;
      crossSystemFor = _profile: spec:
        {
          config = "wasm32-unknown-wasi";
          useLLVM = true;
          isWasix = true;
        }
        // spec;
      configFor = {
        scope,
        nativeRaw,
        ...
      }:
        lib.optionalAttrs (scope == "wasix") {
          allowUnsupportedSystem = true;
          replaceCrossStdenv = (constructionFor nativeRaw).mkWasixStdenv;
        };
      setOverlaysFor = {
        scope,
        nativeRaw,
        ...
      }:
        lib.optionals (includeWasinix && scope == "native") [
          (final: _previous:
            {
              wasi-ghc = import ../overlays/w/wasi-ghc/input.nix {
                inherit ghcWasm;
                pkgs = final;
              };
            }
            // lib.optionalAttrs (wasinixFlake != null) {
              wasinixCapabilityFlake = wasinixFlake;
            }
            // lib.optionalAttrs (wasinixCrane != null) {
              wasinixCraneLib = wasinixCrane.mkLib final;
            }
            // lib.optionalAttrs (wasmerPackage != null) {
              wasmer = import ../overlays/w/wasmer/input.nix {
                wasmer = wasmerPackage;
                revision = wasmerRevision;
              };
            })
        ]
        ++ lib.optionals (scope == "wasix") [
          (constructionFor nativeRaw).wasixInfrastructureOverlay
        ];
      nativePackageInterfacesFor = {
        nativeRaw,
        wasixRaw,
        ...
      }: {
        wasixcc.profiles =
          lib.mapAttrs (profile: _spec: {
            stdenv = wasixRaw.${profile}.stdenv;
          })
          profiles.profiles;
        "wasix-rust".profiles =
          lib.mapAttrs (profile: _spec: {
            rustPlatform = wasixRaw.${profile}.rustPlatform;
          })
          profiles.profiles;
        "wasix-sysroot".profiles =
          nativeRaw."wasix-sysroot".passthru.variants;
        "wasi-ghc" = {
          inherit ((constructionFor nativeRaw).haskell) lib;
          haskellPackages = (constructionFor nativeRaw).haskell.packages;
        };
      };
      projectionContextFor =
        if includeWasinix
        then historyLib.projectionContextFor
        else _args: {};
      validateProject =
        if includeWasinix
        then historyLib.validateProject
        else _args: true;
      packageTransformFor = {
        scope,
        variant,
        packageSet,
      }: _name: package:
        if scope == "wasix"
        then
          compatibility.applyWasixMeta
          variant.profile
          packageSet.stdenv.hostPlatform.system
          package
        else package;
      harnessesFor = {nativeRaw, ...}: (constructionFor nativeRaw).harnesses;
      pythonSetsFor = {wasixRaw, ...}: {
        py313 = {
          pkgs = wasixRaw.exnrefEhpic;
          interpreterPackage = "python313";
          packageSet = wasixRaw.exnrefEhpic.python313.pkgs;
        };
        py314 = {
          pkgs = wasixRaw.exnrefEhpic;
          interpreterPackage = "python314";
          packageSet = wasixRaw.exnrefEhpic.python314.pkgs;
          preferred = true;
        };
      };
      runnersFor = {nativeRaw, ...}: (constructionFor nativeRaw).runners;
    };
  in
    project;
in {
  inherit (projectLib) extendPackage loadPackageOverlays;
  appsForProject = args: (import ./apps.nix ({inherit lib;} // args)).apps;
  cliForProject = args: (import ./apps.nix ({inherit lib;} // args)).cli;
  mkEmptyProject = constructProject false;
  mkProject = constructProject true;
}
