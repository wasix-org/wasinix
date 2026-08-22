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
    };
    pkgs = project.internals.packageSets.nativeRaw;
    inherit (pkgs) lib;
    wasixLib = import ./pkgs/lib {inherit lib;};

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
    allCiJobs = project.ci.jobs;
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
    publicationInfo = let
      registry = project.artifacts.registry.python314;
      cargoRegistryArtifact = project.artifacts.registry.cargo-registry;
      firstChangelog = derivations:
        lib.findFirst (value: value != null) null
        (map (derivation: let
          attempted = builtins.tryEval (derivation.meta.changelog or null);
        in
          if attempted.success
          then attempted.value
          else null)
        derivations);
      informationFor = {
        kind,
        versionOf,
        changelogOf ? (derivation: derivation),
        derivations,
      }: {
        versions = lib.unique (map versionOf derivations);
        inherit kind;
        changelogs =
          lib.mapAttrs (_: values: firstChangelog (map changelogOf values))
          (lib.groupBy versionOf derivations);
        derivations = lib.mapAttrs (_: values:
          map (derivation: builtins.unsafeDiscardStringContext derivation.drvPath) values)
        (lib.groupBy versionOf derivations);
      };
      wheelDerivations = name:
        lib.concatMap (perInterpreter: lib.attrValues (perInterpreter.${name} or {}))
        (lib.attrValues registry.wheels);
      wheelInfo = lib.mapAttrs' (name: _:
        lib.nameValuePair "artifacts.registry.python314.wheels.${name}" (informationFor {
          kind = "wheel";
          versionOf = derivation: derivation.version;
          derivations = wheelDerivations name;
        }))
      registry.wheelVersions;
      webcInfo = lib.mapAttrs' (name: package:
        lib.nameValuePair "artifacts.webc.${name}" (informationFor {
          kind = "webc";
          versionOf = derivation: derivation.id.baseVersion;
          derivations = [package] ++ builtins.attrValues (package.versions or {});
        }))
      project.artifacts.pkg;
      cargoInfo = lib.mapAttrs' (name: _:
        lib.nameValuePair "artifacts.registry.cargo-registry.crates.${name}" (informationFor {
          kind = "crate";
          versionOf = derivation: derivation.passthru.version;
          derivations = builtins.attrValues (cargoRegistryArtifact.crates.${name} or {});
        }))
      cargoRegistryArtifact.crateVersions;
    in
      wheelInfo // webcInfo // cargoInfo;
    updateCandidates = let
      from = prefix: packages:
        lib.mapAttrs' (name: package: lib.nameValuePair "${prefix}.${name}" package)
        (lib.filterAttrs (_: package: (package.passthru.wasinix.source or null) == "wasinix") packages);
    in
      from "packages.native" project.packages.native
      // from "packages.wasix" project.packages.preferred
      // from "packages.python.py314" project.packages.python.py314;
    commandDrvsOf = lib.concatMap (value:
      if lib.isDerivation value
      then [value.drvPath]
      else builtins.attrNames (builtins.getContext (toString value)));
    updateScripts = let
      srcRoot = toString self;
      scriptFor = address: package: let
        declaration = package.passthru.updateScript or null;
        commandValues =
          if lib.isList declaration
          then declaration
          else if lib.isAttrs declaration && declaration ? command
          then lib.toList declaration.command
          else null;
        command =
          if commandValues == null
          then null
          else map toString commandValues;
        position = builtins.unsafeGetAttrPos "updateScript" (package.passthru or {});
        ours =
          command
          != null
          && command != []
          && position != null
          && lib.hasPrefix srcRoot position.file;
        value = lib.optionalAttrs ours {
          ${address} =
            {
              inherit command;
              commandDrvPaths = commandDrvsOf commandValues;
              version = package.version or null;
              position = package.meta.position or null;
            }
            // lib.optionalAttrs (lib.isAttrs declaration && declaration ? name) {inherit (declaration) name;}
            // lib.optionalAttrs (lib.isAttrs declaration && declaration ? attrPath) {inherit (declaration) attrPath;}
            // lib.optionalAttrs (lib.isAttrs declaration && declaration ? accepts) {inherit (declaration) accepts;}
            // lib.optionalAttrs (lib.isAttrs declaration && declaration ? source) {inherit (declaration) source;};
        };
        result = builtins.tryEval (builtins.deepSeq value value);
      in
        if result.success
        then result.value
        else {};
    in
      lib.concatMapAttrs scriptFor updateCandidates;
    updateNotes = let
      noted = lib.filterAttrs (_: wasixLib.hasUpdateNotes) updateCandidates;
      versionOf = package: let
        attempted = builtins.tryEval (wasixLib.noteVersionOf package);
      in
        if attempted.success
        then attempted.value
        else null;
    in {
      versions = lib.mapAttrs (_: versionOf) noted;
      fired = priors:
        lib.filterAttrs (_: notes: notes != [])
        (lib.mapAttrs (address: wasixLib.firedNotesOf (priors.${address} or null)) noted);
    };
    postUpdateHooks = let
      srcRoot = toString self;
      hookFor = address: package: let
        declaration = (package.passthru.wasinix.update or {}).post or null;
        command =
          if declaration == null
          then null
          else map toString (lib.toList declaration);
        position = builtins.unsafeGetAttrPos "wasinix" (package.passthru or {});
        ours =
          command
          != null
          && command != []
          && position != null
          && lib.hasPrefix srcRoot position.file;
        value = lib.optionalAttrs ours {
          ${address} = {
            inherit command;
            commandDrvPaths = commandDrvsOf (lib.toList declaration);
            version = package.version or null;
          };
        };
        result = builtins.tryEval (builtins.deepSeq value value);
      in
        if result.success
        then result.value
        else {};
    in
      lib.concatMapAttrs hookFor updateCandidates;
    systemProject =
      project
      // {
        tests = project.tests;
        catalog.entries = project.catalog.entries;
        internals =
          project.internals
          // {
            publication = {
              info = publicationInfo;
              versions = lib.mapAttrs (_: info: info.versions) publicationInfo;
            };
            updates = {
              inherit postUpdateHooks updateNotes updateScripts;
            };
          };
        ci =
          project.ci
          // {
            jobs = allCiJobs;
            catalog =
              project.ci.catalog
              // {
                jobs = allCiCatalog;
                selectors.sets =
                  project.ci.catalog.selectors.sets
                  // {
                    core = project.ci.catalog.selectors.sets.core or [];
                  };
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
