{
  lib,
  ghcWasm,
  wasmerPackage ? null,
  wasmerRevision ? "dirty",
}: let
  profiles = import ../profiles.nix;
  nativePackageRecipes = import ../native;
  compatibility = import ../lib {inherit lib;};
  constructProject = includeWasinix: {
    system,
    importNixpkgs,
    extensions ? [],
    projectionRules ? {},
    ci ? {},
  }: let
    constructor =
      if includeWasinix
      then projectApi.mkProject
      else projectApi.mkEmptyProject;
    project = constructor {
      inherit system importNixpkgs extensions projectionRules ci;
    };

    constructionFor = nativePkgs: let
      rawWasm = import ../runners/raw-wasm.nix {pkgs = nativePkgs;};
      runtime = nativePkgs.wasmer;
      referenceScanner = nativePkgs.callPackage ../lib/check-reference-scanner.nix {};
      helpers = import ../lib {
        inherit lib referenceScanner;
        snapshotZstd = nativePkgs.zstd;
      };
      toolchain = import ../toolchain {
        pkgs = nativePkgs;
        inherit ghcWasm;
      };
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
        cargo = nativePkgs.cargo;
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
      webcIdent = (import ../wasmer/ident.nix {inherit lib;}).webcIdent;
      testLib = import ../wasmer/test-lib.nix {
        pkgs = nativePkgs;
        wasmer = runtime;
      };
      wasixRun = {
        stub = rawWasm.unbound;
        run = rawWasm.withRuntime runtime;
      };
      emulatedChecks = import ../emulated-check.nix {
        inherit lib wasixRun;
        pkgs = nativePkgs;
      };
      abiCheck = nativePkgs.callPackage ../toolchain/tests/abi-check.nix {
        inherit (toolchain) wasixLlvm binaryen;
      };
      linkCheck = import ../link-check.nix {
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
        import ../python-wheels.nix ({
            inherit lib emulatedChecks mkTestGroup;
            pkgs = nativePkgs;
            wasmer = runtime;
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
        pkgs = nativePkgs;
      };
      harnesses =
        import ../harnesses {
          inherit lib testLib;
          pkgs = nativePkgs;
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
          capturedSuite = emulatedChecks.checkFor;
        };
    in {
      inherit abiCheck emulatedChecks harnesses linkCheck makeWasmerPackage mkCargoRegistry mkPythonRegistry mkPythonWheels mkWasixStdenv testLib wasixInfrastructureOverlay webcIdent;
      runners.rawWasm = {
        inherit (rawWasm) unbound;
        withRuntime = rawWasm.withRuntime runtime;
      };
    };
    builtInExtension = import ../extension.nix {
      inherit (projectApi) loadPackageOverlays;
    };
    historyLib = import ./history.nix {
      inherit lib;
      projectLib = import ./lib.nix {inherit lib;};
    };
    wasinixProjectionRules = {
      historyVersions = {
        namespaces = ["versions"];
        project = {
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
      } @ args: ((import ../artifacts/cargo.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) mkCargoRegistry;
        })
          .registryArtifact
        args);
      wasmerArtifacts = {
        entry,
        packages,
        packageSets,
        ...
      } @ args: ((import ../artifacts/wasmer.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) makeWasmerPackage webcIdent;
        })
          .wasmerArtifacts
        args);
      wasmerCommands = {
        entry,
        packages,
        packageSets,
        ...
      } @ args: ((import ../artifacts/wasmer.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) makeWasmerPackage webcIdent;
        })
          .wasmerCommands
        args);
      inherit
        (import ../checks/behavior.nix {
          inherit lib;
          projectLib = import ./lib.nix {inherit lib;};
        })
        packagedBehavior
        ;
      pythonWheelArtifacts = {
        entry,
        packages,
        packageSets,
        ...
      } @ args: ((import ../artifacts/python.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) mkPythonRegistry mkPythonWheels;
        })
          .wheelArtifacts
        args);
      pythonRegistryArtifact = {
        entry,
        packages,
        packageSets,
        ...
      } @ args: ((import ../artifacts/python.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) mkPythonRegistry mkPythonWheels;
        })
          .registryArtifact
        args);
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
      } @ args: ((import ../checks/link.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) linkCheck;
        })
          .packageLink
        args);
      packageAbi = {
        entry,
        packageSets,
        profileSets,
        ...
      } @ args: ((import ../checks/abi.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) abiCheck;
        })
          .packageAbi
        args);
      capturedSuite = {
        entry,
        packageSets,
        ...
      } @ args: ((import ../checks/captured.nix {
          inherit lib;
          inherit ((constructionFor packageSets.native)) emulatedChecks;
        })
          .capturedSuite
        args);
    };
    projectApi = import ./default.nix {
      inherit lib profiles builtInExtension;
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
        lib.optionals (includeWasinix && scope == "native" && wasmerPackage != null) [
          (_final: _previous: {
            wasmer = import ../native/wasmer/input.nix {
              wasmer = wasmerPackage;
              revision = wasmerRevision;
            };
          })
        ]
        ++ lib.optionals (scope == "wasix") [
          (nativePackageRecipes.overlay {nativeNixUpdateScript = nativeRaw.nix-update-script;})
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
          packageSet = wasixRaw.exnrefEhpic.python313.pkgs;
        };
        py314 = {
          pkgs = wasixRaw.exnrefEhpic;
          packageSet = wasixRaw.exnrefEhpic.python314.pkgs;
        };
      };
      runnersFor = {nativeRaw, ...}: (constructionFor nativeRaw).runners;
    };
  in
    project;
in {
  mkEmptyProject = constructProject false;
  mkProject = constructProject true;
}
