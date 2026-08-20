{
  lib,
  ghcWasm,
  wasmerRuntime ? null,
}: let
  profiles = import ../profiles.nix;
  nativePackageRecipes = import ../native;
in {
  mkProject = {
    system,
    importNixpkgs,
    extensions ? [],
    ci ? {},
  }: let
    # Cross sets consume the catalogued native toolchain through unregistered
    # overlays; registering those recipes again would duplicate their ownership.
    project = projectApi.mkProject {
      inherit system extensions ci;
      importNixpkgs = args:
        importNixpkgs (
          args
          // {
            overlays =
              lib.optionals (args ? crossSystem) [
                (nativePackageRecipes.overlay {nativeNixUpdateScript = nativePkgs.nix-update-script;})
                wasixInfrastructureOverlay
              ]
              ++ (args.overlays or []);
          }
        );
    };

    nativePkgs = project.internals.packageSets.nativeRaw;
    rawWasm = import ../runners/raw-wasm.nix {pkgs = nativePkgs;};
    runtime =
      if wasmerRuntime == null
      then nativePkgs.wasmer
      else wasmerRuntime;
    referenceScanner = nativePkgs.callPackage ../lib/check-reference-scanner.nix {};
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

    projectApi = import ./default.nix {
      inherit lib profiles;
      builtInExtension = import ../extension.nix {
        inherit (projectApi) loadPackageOverlays;
      };
      crossSystemFor = _profile: spec:
        {
          config = "wasm32-unknown-wasi";
          useLLVM = true;
          isWasix = true;
        }
        // spec;
      configFor = scope: _variant:
        lib.optionalAttrs (scope == "wasix") {
          allowUnsupportedSystem = true;
          replaceCrossStdenv = mkWasixStdenv;
        };
      nativePackageInterfacesFor = project': {
        wasixcc.profiles =
          lib.mapAttrs (profile: _spec: {
            stdenv = project'.internals.packageSets.wasixRaw.${profile}.stdenv;
          })
          profiles.profiles;
        "wasix-rust".profiles =
          lib.mapAttrs (profile: _spec: {
            rustPlatform = project'.internals.packageSets.wasixRaw.${profile}.rustPlatform;
          })
          profiles.profiles;
        "wasix-sysroot".profiles =
          lib.mapAttrs (profile: _spec: {
            inherit (project'.internals.packageSets.nativeRaw."wasix-sysroot".passthru.variants.${profile}) sysroot;
          })
          profiles.profiles;
      };
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
      runnersFor = _project: {
        rawWasm = {
          inherit (rawWasm) unbound;
          withRuntime = rawWasm.withRuntime runtime;
        };
      };
    };
  in
    project;
}
