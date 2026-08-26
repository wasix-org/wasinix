{lib}: let
  projectLib = import ./lib.nix {inherit lib;};

  mkPackage = attrs: let
    package =
      {
        type = "derivation";
        name = attrs.name or "test-package";
        passthru = attrs.passthru or {};
        overrideAttrs = update: mkPackage (attrs // update attrs);
      }
      // attrs;
  in
    package;

  hookPackage = name: version: post:
    mkPackage {
      inherit name version;
      passthru.wasinix = {
        source = "fixture";
        update = {inherit post;};
      };
    };
  ownedUpdatePackage = mkPackage {
    name = "owned-update";
    version = "1";
    passthru = {
      updateScript = ["./update-owned"];
      wasinix = {
        source = "fixture";
        ownership = {
          assignees = [{github = "jane-doe";}];
          reviewers = [{github = "jane-doe";}];
        };
      };
    };
  };
  repository = import ./repository.nix {
    inherit lib;
    root = ../..;
    source = "fixture";
    revisionsFile = ../../release-revisions.json;
    project = {
      packages = {
        native = {
          command = hookPackage "command" "1" ["./hook"];
          ownedUpdate = ownedUpdatePackage;
          sync = hookPackage "sync" "2" {
            syncAttrList = {
              input = "nixpkgs";
              attrPath = "legacyPackages.\${system}";
              match = "^icu([0-9]+)$";
              capture = 1;
              probe = "version";
              sort = "numeric";
              destination = "versions.nix";
            };
          };
        };
        wasix.preferred.cli = mkPackage {
          name = "cli";
          version = "1";
          passthru = {
            updateScript = ["./update"];
            wasinix.source = "fixture";
          };
        };
        python = {};
      };
      artifacts = {};
      ownership.fixture = {
        maintainers.janeDoe.github = "jane-doe";
        teams.core = [];
      };
      catalog.entries = {
        "artifacts.wheel-py313.demo" = {
          kind = "artifact";
          artifactKind = "wheel-py313";
          name = "demo";
          source = "fixture";
          instance = {
            kind = "current";
            version = "3";
          };
          policy.retention = "minor";
        };
        "artifacts.wheel-py313.demo.versions.\"2\"" = {
          kind = "artifact";
          artifactKind = "wheel-py313";
          name = "demo";
          source = "fixture";
          instance = {
            kind = "history";
            version = "2";
          };
          policy.retention = "minor";
        };
        "packages.wasix.default.cli" = {
          kind = "package";
          name = "cli";
          source = "fixture";
          scope = "wasix";
          preferred = true;
          instance = {
            kind = "current";
            version = "1";
          };
          policy = {
            shipped = true;
            retention = "major";
          };
        };
      };
    };
  };
  repositoryHooks = repository.updates.postUpdateHooks;
  repositoryScripts = repository.updates.updateScripts;

  dependency = mkPackage {name = "dependency";};
  previous = mkPackage {
    name = "existing";
    buildInputs = [];
  };
  pythonBuildEdit = projectLib.extendPythonPackage (package: package) previous {patches = ["fix.patch"];};
  pythonTestEdit = projectLib.extendPythonPackage (package: package) previous {doCheck = false;};
  repairPythonPackage = import ../python/lib/repair.nix {
    inherit lib;
    inherit (projectLib) mergeScript;
  };
  buildBackendPackages = {
    pdm-backend = mkPackage {name = "pdm-backend";};
    hatchling = mkPackage {name = "hatchling";};
    flit-core = mkPackage {name = "flit-core";};
    poetry-core = mkPackage {name = "poetry-core";};
    cython = mkPackage {name = "cython";};
    setuptools = mkPackage {name = "setuptools";};
    wheel = mkPackage {name = "wheel";};
  };
  repairPython = {
    pkgs.requiredPythonModules = inputs: map (input: input.name) inputs;
    pythonOnBuildForHost = {
      pkgs = buildBackendPackages;
      sitePackages = "lib/python/site-packages";
      withPackages = select: builtins.deepSeq (select buildBackendPackages) "/build-backends";
    };
    sitePackages = "lib/python/site-packages";
  };
  historyRepairOnce = repairPythonPackage (mkPackage {
    name = "history-repair";
    nativeBuildInputs = [
      (mkPackage {name = "pyproject-version-patch-hook.sh";})
    ];
    passthru.wasix.historySpec = {};
    propagatedBuildInputs = [dependency];
    pythonModule = repairPython;
  });
  historyRepairTwice = repairPythonPackage historyRepairOnce;
  newRecipe = mkPackage {name = "new";};
  familyA = mkPackage {name = "family-a";};
  familyB = mkPackage {name = "family-b";};
  final = {
    inherit dependency newRecipe familyA familyB;
    callPackage = file: overrides:
      projectLib.callWithLabel "test-package-unit" (final // overrides) (import file);
  };
  prev = {
    inherit dependency;
    existing = previous;
    family-a = familyA;
    family-b = familyB;
    new = throw "an exposePackage unit must not force its preceding value";
  };
  contextFor = {final, ...}: {
    packages.sameProfile = final;
    inherit (projectLib) extendPackage;
  };
  loadedRaw =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/units;
    }
    final
    prev;
  loaded = removeAttrs loadedRaw [projectLib.compatibilityAttr projectLib.identityAttr projectLib.unitOverlaysAttr];
  discoveredUnits = projectLib.discoverUnits ./tests/units;
  conflictingUnits = projectLib.discoverUnits ./tests/conflicting-units;
  invalidShardedUnits = projectLib.discoverShardedInventory {
    dir = ./tests/invalid-sharded;
    lane = "packages";
  };
  inheritedRaw =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/units;
      inherited.dependency.supportedProfiles = ["eh"];
      scope = "wasix";
    }
    final
    prev;
  inheritedLoaded = removeAttrs inheritedRaw [projectLib.compatibilityAttr projectLib.identityAttr projectLib.unitOverlaysAttr];
  replayedInherited = inheritedRaw.${projectLib.unitOverlaysAttr}.dependency.overlay final prev;
  nativeInherited =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/units;
      inherited.dependency = {};
      scope = "native";
    }
    final
    prev;
  topLevelPackageFiles = lib.attrNames (lib.filterAttrs (name: type: type == "regular" && lib.hasSuffix ".nix" name) (builtins.readDir ../.));
  bareUnit =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/invalid-units;
    }
    final
    prev;
  exposedUnits =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/units;
      expose = ["dependency"];
    }
    final
    prev;
  missingExposure =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/units;
      expose = ["missing"];
    }
    final
    prev;
  missingInherited =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/units;
      inherited.missing = {};
      scope = "wasix";
    }
    final
    prev;
  conflictingInherited =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/units;
      inherited.existing = {};
      scope = "wasix";
    }
    final
    prev;
  invalidInherited =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/units;
      inherited.dependency = true;
      scope = "wasix";
    }
    final
    prev;
  shardedPrev = {
    alpha = mkPackage {name = "alpha-native";};
    beta = mkPackage {name = "beta-native";};
  };
  shardedFinal = shardedPrev // {alphaBase = mkPackage {name = "alpha-base";};};
  shardedContextFor = scope: {final, ...}: {
    inherit scope;
    packageSet = final;
    packages.sameProfile = final;
    inherit (projectLib) extendPackage;
  };
  shardedNative =
    projectLib.loadPackageOverlay {
      contextFor = shardedContextFor "native";
      dir = ./tests/sharded-units;
      part = "base";
      sharded = true;
      scope = "native";
    }
    shardedFinal
    shardedPrev;
  shardedWasixBase =
    projectLib.loadPackageOverlay {
      contextFor = shardedContextFor "wasix";
      dir = ./tests/sharded-units;
      part = "base";
      sharded = true;
      scope = "wasix";
    }
    shardedFinal
    shardedPrev;
  shardedWasix =
    projectLib.loadPackageOverlay {
      contextFor = shardedContextFor "wasix";
      dir = ./tests/sharded-units;
      part = "wasix";
      sharded = true;
      scope = "wasix";
    }
    (shardedFinal // shardedWasixBase)
    (shardedPrev // shardedWasixBase);

  coreOverlay = projectLib.registerOverlay {
    source = "wasinix";
    overlay = _final: _prev: {
      owned = mkPackage {name = "owned";};
      plumbing = mkPackage {
        name = "plumbing";
        passthru.wasinix.catalog = false;
      };
    };
  };
  core = coreOverlay {} {};
  extensionOverlay = projectLib.registerOverlay {
    source = "my-project";
    overlay = _final: previous: {
      owned = projectLib.extendPackage previous.owned {
        passthru.wasinix.overrides = "wasinix";
      };
    };
  };
  extension = extensionOverlay {} core;
  missingDeclaration = projectLib.registerOverlay {
    source = "my-project";
    overlay = _final: previous: {inherit (previous) owned;};
  };
  orphanDeclaration = projectLib.registerOverlay {
    source = "my-project";
    overlay = _final: _previous: {
      orphan = mkPackage {
        name = "orphan";
        passthru.wasinix.overrides = "wasinix";
      };
    };
  };
  authoredDefinition = projectLib.registerOverlay {
    source = "my-project";
    overlay = _final: _previous: {
      authored = mkPackage {
        passthru.wasinix.definition = {
          file = "authored.nix";
          directory = null;
        };
      };
    };
  };
  changedDefinition = projectLib.registerOverlay {
    source = "my-project";
    overlay = _final: previous': {
      owned = previous'.owned.overrideAttrs (old: {
        passthru =
          old.passthru
          // {
            wasinix =
              old.passthru.wasinix
              // {
                definition = {
                  file = "changed.nix";
                  directory = null;
                };
                overrides = "wasinix";
              };
          };
      });
    };
  };
  force = value: builtins.tryEval (builtins.deepSeq value value);

  mkPythonSet = overlays:
    lib.fix (final:
      builtins.foldl' (previous: overlay: previous // overlay final previous) {
        inheritedPython = mkPackage {name = "inherited-python";};
        python = mkPackage {
          name = "python";
          stdenv.hostPlatform.isWasix = true;
        };
        overrideScope = overlay: mkPythonSet (overlays ++ [overlay]);
      }
      overlays);

  testHistoryLib = import ./history.nix {
    inherit lib projectLib;
    rebasePackageOverride = version: spec: package:
      package.overrideAttrs (old: {
        inherit version;
        name = "${package.name}-${version}";
        passthru = (old.passthru or {}) // {inherit spec;};
      });
  };
  projectApiArgs = {
    inherit lib;
    profiles = {
      profiles = {
        default = {};
        alternate = {};
      };
      defaultProfileName = "default";
      profileOf = platform: platform.wasinixProfile;
      sysrootEncodings = {
        default = {};
        alternate = {};
      };
    };
    builtInExtension = {
      id = "wasinix";
      overlays.packages = _final: _previous: {
        core = mkPackage {
          name = "core";
          passthru = {
            wasix.preferredProfile = "alternate";
            wasmer.name = "core";
          };
        };
      };
      overlays.python = _final: _previous: _pyfinal: _pyprevious: {
        corePython = mkPackage {name = "core-python";};
      };
    };
    crossSystemFor = profile: _spec: {wasinixProfile = profile;};
    pythonSetsFor = {wasixRaw, ...}: {
      py = {
        pkgs = wasixRaw.default;
        interpreterPackage = "core";
        packageSet = mkPythonSet [];
        preferred = true;
      };
    };
    nativePackageInterfacesFor = {project, ...}: {
      core.profiles.default.package = project.packages.wasix.default.core;
    };
    packageTransformFor = {scope, ...}: _name: package:
      if scope == "wasix"
      then
        package.overrideAttrs (old: {
          passthru = (old.passthru or {}) // {transformed = true;};
        })
      else package;
    runnersFor = _args: {
      rawWasm.unbound = mkPackage {name = "raw-wasm-unbound";};
    };
    inherit (testHistoryLib) projectionContextFor validateProject;
  };
  fakeWebcIdent = package: {
    name = package.passthru.wasmer.name or package.pname or package.name;
    baseVersion = toString (package.version or package.name);
  };
  fakeMakeWasmerPackage = {
    package,
    servedVersions ? null,
  }: let
    webc = mkPackage {
      name = "webc-${package.name}";
      shim = mkPackage {name = "shim-${package.name}";};
      passthru.wasmer.package = package;
    };
  in
    mkPackage {
      name = "pkg-${package.name}";
      inherit webc;
      passthru = {inherit servedVersions;};
    };
  wasmerProjectionModule = import ../artifacts/wasmer.nix {
    inherit lib;
    makeWasmerPackage = fakeMakeWasmerPackage;
    webcIdent = fakeWebcIdent;
  };
  wasmerProjectionRules = {
    inherit (wasmerProjectionModule) wasmerArtifacts wasmerCommands;
  };
  behaviorProjectionRules = import ../checks/behavior.nix {
    inherit lib projectLib;
  };
  historyProjectionRules.historyVersions = {
    namespaces = ["versions"];
    entry = {
      entry,
      instantiateVersions,
      ...
    }: {
      versions = instantiateVersions entry;
    };
  };
  fakeTestLib = {
    defaultForwardEnv = ["HOME"];
    defaultTimeout = 300;
    defaultWasixTimeout = 600;
    normalizers = {};
    mkScriptComparison = args:
      mkPackage {
        name = "comparison-${args.name}";
        passthru.harnessArgs = args;
      };
    mkWasixRun = args:
      mkPackage {
        name = "host-shell-${args.name}";
        passthru.harnessArgs = args;
      };
  };
  fakeHarnesses =
    import ../harnesses {
      inherit lib;
      makeWasmerPackage = fakeMakeWasmerPackage;
      pkgs = {
        runCommand = name: attrs: script:
          mkPackage {
            inherit name script;
            passthru.runCommandAttrs = attrs;
          };
        writeShellScript = name: script: mkPackage {inherit name script;};
        writeText = name: text: mkPackage {inherit name text;};
      };
      testLib = fakeTestLib;
      wasmer = mkPackage {name = "wasmer";};
    }
    // {
      packageCommands = package: {
        ${package.pname or package.name} = {
          artifact = mkPackage {
            name = "webc-${package.name}";
            shim = mkPackage {name = "shim-${package.name}";};
            passthru.wasmer.package = package;
          };
          entrypoint = package.pname or package.name;
          name = package.pname or package.name;
          inherit package;
        };
      };
    };
  duplicateHarnessCommand = {
    name = "duplicate";
    entrypoint = "duplicate";
    artifact = mkPackage {
      name = "duplicate-webc";
      shim = mkPackage {name = "duplicate-shim";};
      passthru.wasmer.package = mkPackage {name = "duplicate-package";};
    };
  };
  fakeShellPackage = mkPackage {
    name = "bash";
    passthru.wasmer.commands = [{name = "bash";}];
  };
  fakeGuestPackage = mkPackage {name = "guest-command";};
  fakeShellCommand = {
    name = "bash";
    entrypoint = "bash";
    package = fakeShellPackage;
    artifact = (fakeMakeWasmerPackage {package = fakeShellPackage;}).webc;
  };
  fakeGuestCommand = {
    name = "guest-command";
    entrypoint = "guest-command";
    package = fakeGuestPackage;
    artifact = (fakeMakeWasmerPackage {package = fakeGuestPackage;}).webc;
  };
  fakeWasixShell = fakeHarnesses.wasixShell {
    name = "guest-workflow";
    shell = fakeShellCommand;
    commands = [fakeGuestCommand];
    runtime = {
      network = true;
      threads = true;
    };
    host = {
      packages = [dependency];
      setup = "export FIXTURE=ready";
      teardown = "test -n \"$FIXTURE\"";
    };
    forwardEnv = ["FIXTURE"];
    script = "guest-command";
  };
  projectApi = import ./default.nix (projectApiArgs
    // {
      harnessesFor = _args: fakeHarnesses;
      projectionRules = {
        inherit (historyProjectionRules) historyVersions;
        probe = {
          entry,
          packages,
          ...
        }:
          lib.optionalAttrs (entry.kind == "package" && entry.policy.checks.probe or false) {
            tests.probe = mkPackage {name = "probe-${entry.package.name}-${packages.sameProfile.core.versions."0.9".version}";};
          };
        package = {entry, ...}:
          lib.optionalAttrs (
            entry.kind
            == "package"
            && entry.address == "packages.wasix.default.consumer"
          ) (let
            bundle = mkPackage {name = "consumer-bundle";};
          in {
            artifacts.bundle = bundle;
            commands.consumer = {
              name = "consumer";
              artifact = bundle;
              entrypoint = "consumer";
            };
          });
        packaged = {
          commands,
          entry,
          ...
        }:
          lib.optionalAttrs (entry.kind == "artifact" && entry.artifactKind == "bundle") {
            tests.packaged = mkPackage {name = "packaged-${entry.artifact.name}-${commands.consumer.name}";};
          };
      };
    });
  fakeImportNixpkgs = args: let
    base = {
      inherit dependency newRecipe familyA familyB;
      family-a = familyA;
      family-b = familyB;
      behavior = mkPackage {
        name = "behavior";
        version = "1.0";
      };
      existing = previous;
      inherited = mkPackage {name = "inherited";};
      unpackaged = mkPackage {
        name = "unpackaged";
        version = "1.0";
      };
      profile = args.crossSystem.wasinixProfile or "native";
      replacement = mkPackage {
        name = "base-replacement";
        version = "0.1";
      };
      writeText = name: text:
        mkPackage {
          inherit name;
          passthru = {inherit text;};
        };
      stdenv.hostPlatform.isWasix = args ? crossSystem;
    };
  in
    lib.fix (final:
      builtins.foldl' (previous: overlay: previous // overlay final previous)
      (base
        // {
          callPackage = file: overrides:
            projectLib.callWithLabel "test-package-unit" (final // overrides) (import file);
        })
      args.overlays);
  consumerExtension = {
    id = "consumer";
    history = {
      wasix = ./tests/wasix-history.json;
      python = ./tests/python-history.json;
    };
    overlays = {
      packages = final: previous: {
        core = projectLib.extendPackage previous.core {
          passthru.wasinix = {
            overrides = "wasinix";
            checks.probe = true;
            ci.profiles = ["default" "alternate"];
          };
        };
        consumer = mkPackage {
          name = "consumer-${final.profile}";
          passthru.wasinix.checks.probe = true;
        };
        "dot.name" = mkPackage {name = "dot-name";};
        limited = mkPackage {
          name = "limited-${final.profile}";
          passthru.wasix.supportedProfiles = ["alternate"];
        };
        ciNarrow = mkPackage {
          name = "ci-narrow-${final.profile}";
          passthru.wasinix.ci.profiles = ["default"];
        };
        broken = mkPackage {
          name = "broken-${final.profile}";
          meta.broken = true;
        };
        plumbing = mkPackage {
          name = "plumbing";
          passthru.wasinix.catalog = false;
        };
      };
      inherit
        ((projectApi.loadPackageOverlays {
          python = ./tests/python-units;
        }))
        python
        ;
    };
  };
  unitExtension = {
    id = "unit-consumer";
    ownership = let
      maintainers.janeDoe.github = "jane-doe";
    in {
      inherit maintainers;
      teams.core = [];
      teams.php = [maintainers.janeDoe];
    };
    overlays = projectApi.loadPackageOverlays {
      packages = ./tests/project-units;
    };
  };
  definitionExtension = {
    id = "definition-consumer";
    history.wasix = ./tests/unit-history.json;
    overlays = projectApi.loadPackageOverlays {
      packages = ./tests/units;
    };
  };
  pythonContextExtension = {
    id = "python-context";
    overlays = {
      packages = _final: _previous: {
        topOwned = mkPackage {name = "top-owned";};
      };
      python = final: previous: _pyfinal: _pyprevious: {
        contextProof = mkPackage {
          name = "${final.topOwned.name}-${toString (previous ? topOwned)}";
        };
      };
    };
  };
  pythonRepairExtension = {
    id = "python-repair";
    overlays.python = _final: _previous: _pyfinal: _pyprevious: {
      repairPython = mkPackage {
        name = "repair-python";
        propagatedBuildInputs = [dependency];
        pythonModule.pkgs.requiredPythonModules = inputs: map (package: package.name) inputs;
        passthru.requiredPythonModules = ["stale"];
      };
    };
  };
  emptyExtension = {
    id = "empty";
    overlays.packages = _final: _previous: {
      core = mkPackage {name = "empty-core";};
      only = mkPackage {name = "only";};
    };
  };
  emptyProject = projectApi.mkEmptyProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [emptyExtension];
    projectionRules.perProject = {
      namespaces = ["tests"];
      entry = {entry, ...}:
        lib.optionalAttrs (entry.address == "packages.wasix.default.core") {
          tests.per-project = mkPackage {name = "per-project";};
        };
    };
  };
  project = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [consumerExtension unitExtension pythonContextExtension];
    ci = {
      sources = ["consumer"];
      groups.fixture = {
        jobs = ["packages.wasix.alternate.consumer"];
      };
    };
  };
  definitionProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [definitionExtension];
  };
  pythonRepairProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [pythonRepairExtension];
  };
  projectTestProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    ci.sources = ["wasinix"];
    projectTests.format = {
      source = "wasinix";
      check = _project: mkPackage {name = "format";};
    };
  };
  wasmerProjectApi = import ./default.nix (projectApiArgs // {projectionRules = historyProjectionRules // wasmerProjectionRules;});
  behaviorProjectApi = import ./default.nix (projectApiArgs
    // {
      harnessesFor = _args: fakeHarnesses;
      projectionRules = historyProjectionRules // wasmerProjectionRules // behaviorProjectionRules;
    });
  wasmerExtension = {
    id = "wasmer-fixture";
    history.wasix = ./tests/wasix-history.json;
    overlays.packages = final: previous: {
      core = projectLib.extendPackage previous.core {
        passthru.wasinix = {
          overrides = "wasinix";
          shipped = true;
        };
      };
      auto = mkPackage {
        name = "auto-${final.profile}";
        version = "1.0";
        passthru = {
          wasmer = {
            name = "auto";
            entrypoint = "launch";
          };
          wasinix = {
            aliases = ["automatic"];
            shipped = true;
          };
        };
      };
      explicit = mkPackage {
        name = "explicit-${final.profile}";
        version = "2.0";
        passthru = {
          wasmer.commands = [
            {name = "first";}
            {name = "second";}
            {
              name = "local";
              global = false;
            }
            {
              name = "dependency";
              dependency.package = dependency;
            }
          ];
          wasinix.shipped = true;
        };
      };
      data = mkPackage {
        name = "data-${final.profile}";
        version = "3.0";
        passthru = {
          wasmer.commands = [];
          wasinix.shipped = true;
        };
      };
      unshipped = mkPackage {name = "unshipped-${final.profile}";};
    };
  };
  behaviorExtension = {
    id = "behavior-fixture";
    history.wasix = ./tests/behavior-history.json;
    overlays = projectApi.loadPackageOverlays {
      packages = ./tests/behavior-units;
    };
  };
  wasmerProject = wasmerProjectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [wasmerExtension];
  };
  behaviorProject = behaviorProjectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [behaviorExtension];
    ci.sources = ["behavior-fixture"];
  };
  wasmerValidationProject = id: commands:
    wasmerProjectApi.mkProject {
      system = "test-system";
      importNixpkgs = fakeImportNixpkgs;
      extensions = [
        {
          inherit id;
          overlays.packages = _final: _previous: {
            probe = mkPackage {
              name = "probe";
              version = "1.0";
              passthru = {
                wasmer = {inherit commands;};
                wasinix.shipped = true;
              };
            };
          };
        }
      ];
    };
  unnamedWasmerCommandProject = wasmerValidationProject "unnamed-command" [{}];
  invalidWasmerCommandsProject = wasmerValidationProject "invalid-commands" "not a list";
  duplicateWasmerCommandProject = wasmerValidationProject "duplicate-command" [
    {name = "same";}
    {name = "same";}
  ];
  unknownCiSource = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [consumerExtension];
    ci.sources = ["missing"];
  };
  duplicateExtension = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [consumerExtension consumerExtension];
  };
  invalidMaintainerOwnership = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "invalid-maintainer";
        ownership.maintainers.invalid.github = "";
      }
    ];
  };
  invalidTeamOwnership = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "invalid-team";
        ownership = {
          maintainers.janeDoe.github = "jane-doe";
          teams.php = [{github = "outside-registry";}];
        };
      }
    ];
  };
  nonPackageOverlayProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "non-package";
        overlays.packages = _final: _previous: {helper = "not-a-package";};
      }
    ];
  };
  aliasCollisionProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "alias-collision";
        overlays.packages = _final: _previous: {
          first = mkPackage {passthru.wasinix.aliases = ["shared"];};
          second = mkPackage {passthru.wasinix.aliases = ["shared"];};
        };
      }
    ];
  };
  variantShapeProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "variant-shape";
        overlays.packages = _final: previous:
          lib.optionalAttrs (previous.profile == "default") {
            conditional = mkPackage {name = "conditional";};
          };
      }
    ];
  };
  staleHistoryProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "stale-history";
        history.wasix = ./tests/wasix-history.json;
      }
    ];
  };
  replacementHistoryProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "replacement-history";
        history.wasix = ./tests/replacement-history.json;
        overlays.packages = _final: _previous: {
          replacement = mkPackage {
            name = "standalone-replacement";
            version = "1.0";
          };
        };
      }
    ];
  };
  invalidProfileProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "invalid-profile";
        overlays.packages = _final: _previous: {
          invalidProfile = mkPackage {
            passthru.wasix.supportedProfiles = ["missing"];
          };
        };
      }
    ];
  };
  invalidCiProfileProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "invalid-ci-profile";
        overlays.packages = _final: _previous: {
          invalidCiProfile = mkPackage {
            passthru.wasix.supportedProfiles = ["alternate"];
            passthru.wasinix.ci.profiles = ["default"];
          };
        };
      }
    ];
  };
  invalidNativeInterfaceProject = (import ./default.nix (projectApiArgs
    // {
      nativePackageInterfacesFor = _args: {
        missing.profiles = {};
      };
    })).mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
  };
  projectWithProjectionRules = projectionRules:
    (import ./default.nix (projectApiArgs // {projectionRules = historyProjectionRules // projectionRules;})).mkProject {
      system = "test-system";
      importNixpkgs = fakeImportNixpkgs;
      extensions = [consumerExtension];
    };
  aggregateProjectionRules = {
    bundle = {entry, ...}:
      lib.optionalAttrs (entry.address == "packages.wasix.default.consumer") {
        artifacts.bundle = mkPackage {name = "consumer-bundle";};
      };
    aggregate = {
      source = "consumer";
      namespaces = ["artifacts" "tests"];
      project = {
        packages,
        pythonVariants,
        ...
      }: {
        artifacts.aggregate.fixture = {
          artifact = mkPackage {name = "aggregate-${packages.wasix.default.consumer.name}-${pythonVariants.preferred}";};
          subjects = ["artifacts.bundle.consumer"];
        };
      };
      entry = {entry, ...}:
        lib.optionalAttrs (entry.kind == "artifact" && entry.artifactKind == "aggregate") {
          tests.inspect = mkPackage {name = "inspect-${entry.artifact.name}";};
        };
    };
  };
  aggregateProjectionProject = projectWithProjectionRules aggregateProjectionRules;
  duplicateAggregateProject = projectWithProjectionRules {
    first = {
      source = "consumer";
      namespaces = ["artifacts"];
      project = _context: {artifacts.aggregate.same = mkPackage {};};
    };
    second = {
      source = "consumer";
      namespaces = ["artifacts"];
      project = _context: {artifacts.aggregate.same = mkPackage {};};
    };
  };
  unknownAggregateSourceProject = projectWithProjectionRules {
    aggregate = {
      source = "missing";
      namespaces = ["artifacts"];
      project = _context: {artifacts.aggregate.fixture = mkPackage {};};
    };
  };
  invalidAggregateSubjectsProject = projectWithProjectionRules {
    aggregate = {
      source = "consumer";
      namespaces = ["artifacts"];
      project = _context: {
        artifacts.aggregate.fixture = {
          artifact = mkPackage {};
          subjects = ["artifacts.missing"];
        };
      };
    };
  };
  malformedAggregateSubjectsProject = projectWithProjectionRules {
    aggregate = {
      source = "consumer";
      namespaces = ["artifacts"];
      project = _context: {
        artifacts.aggregate.fixture = {
          artifact = mkPackage {};
          subjects = "artifacts.bundle.consumer";
        };
      };
    };
  };
  pythonArtifactModule = import ../artifacts/python.nix {
    inherit lib;
    mkPythonRegistry = args:
      mkPackage {
        name = "python-registry";
        passthru.registryArgs = args;
      };
    mkPythonWheels = _args: {};
  };
  pythonRegistryFor = preferred: let
    interpreterPackages = {
      old = "python-old";
      new = "python-new";
    };
    runtimeFor = interpreter: mkPackage {name = "runtime-${interpreter}";};
    webcFor = interpreter: let
      package = mkPackage {name = interpreter;};
      artifact = mkPackage {
        name = "webc-${interpreter}";
        shim = mkPackage {name = "webc-${interpreter}";};
      };
    in {
      artifacts.webc =
        artifact
        // {
          commands.python = {
            inherit artifact package;
            name = "python";
            entrypoint = "python";
          };
        };
    };
    result = pythonArtifactModule.registryArtifact {
      catalog.entries = {};
      packages = {
        wasix.preferred = lib.mapAttrs' (_: interpreterPackage:
          lib.nameValuePair interpreterPackage (webcFor interpreterPackage))
        interpreterPackages;
        python = lib.genAttrs (lib.attrNames interpreterPackages) (_: {});
      };
      packageSets.wasix.preferred = lib.mapAttrs' (_: interpreterPackage:
        lib.nameValuePair interpreterPackage (runtimeFor interpreterPackage))
      interpreterPackages;
      pythonVariants = {
        all = lib.attrNames interpreterPackages;
        inherit preferred;
        specs = lib.mapAttrs (_: interpreterPackage: {inherit interpreterPackage;}) interpreterPackages;
      };
    };
  in
    result.artifacts.registry.python.artifact.passthru.registryArgs;
  duplicateProjectionProject = projectWithProjectionRules {
    first = {entry, ...}: lib.optionalAttrs (entry.policy.checks.probe or false) {tests.same = mkPackage {};};
    second = {entry, ...}: lib.optionalAttrs (entry.policy.checks.probe or false) {tests.same = mkPackage {};};
  };
  duplicateArtifactProject = projectWithProjectionRules {
    duplicate = {entry, ...}:
      lib.optionalAttrs (
        entry.kind
        == "package"
        && entry.scope == "wasix"
        && entry.name == "core"
        && entry.instance.kind == "current"
      ) {artifacts.bundle = mkPackage {};};
  };
  duplicateCommandProject = projectWithProjectionRules {
    duplicate = {entry, ...}:
      lib.optionalAttrs (
        entry.kind
        == "package"
        && entry.scope == "wasix"
        && entry.name == "core"
        && entry.instance.kind == "current"
      ) {
        commands.core = {
          name = "core";
          artifact = mkPackage {};
          entrypoint = "core";
        };
      };
  };
  typedNamespaceProject = projectWithProjectionRules {
    same = {entry, ...}:
      lib.optionalAttrs (entry.address == "packages.wasix.default.consumer") {
        artifacts.same = mkPackage {name = "same-artifact";};
        tests.same = mkPackage {name = "same-test";};
      };
  };
  historyProjectionProject = projectWithProjectionRules {
    retained = {entry, ...}:
      lib.optionalAttrs (
        entry.kind
        == "package"
        && entry.scope == "wasix"
        && entry.variant.profile == "default"
        && entry.name == "core"
      ) {
        artifacts.retained = mkPackage {name = "retained-${entry.instance.version}";};
      };
    inspect = {entry, ...}:
      lib.optionalAttrs (entry.kind == "artifact" && entry.artifactKind == "retained") {
        tests.inspect = mkPackage {name = "inspect-${entry.artifact.name}";};
      };
  };
  invalidProjectionProject = projectWithProjectionRules {
    invalid = {entry, ...}: lib.optionalAttrs (entry.policy.checks.probe or false) {tests.invalid = "not a derivation";};
  };
  invalidArtifactProject = projectWithProjectionRules {
    invalid = {entry, ...}: lib.optionalAttrs (entry.policy.checks.probe or false) {artifacts.invalid = "not a derivation";};
  };
  invalidCommandProject = projectWithProjectionRules {
    invalid = {entry, ...}:
      lib.optionalAttrs (entry.policy.checks.probe or false) {
        commands.invalid = {
          name = "mismatched";
          artifact = mkPackage {};
          entrypoint = "invalid";
        };
      };
  };
  invalidNamespaceProject = projectWithProjectionRules {
    invalid = {entry, ...}: lib.optionalAttrs (entry.policy.checks.probe or false) {unknown = {};};
  };
  invalidNamespaceShapeProject = projectWithProjectionRules {
    invalid = {entry, ...}: lib.optionalAttrs (entry.policy.checks.probe or false) {tests = "not an attribute set";};
  };
  invalidResultProject = projectWithProjectionRules {
    invalid = _args: "not an attribute set";
  };
  invalidRuleProject = projectWithProjectionRules {
    invalid.namespaces = ["artifacts"];
  };
  extensionDeclaration = import ./extension.nix {inherit (projectLib) loadPackageOverlays;};
  expectedCiJobNames = [
    "artifacts.bundle.consumer"
    ''packages.native."dot.name"''
    "packages.native.ciNarrow"
    "packages.native.consumer"
    "packages.native.core"
    "packages.native.limited"
    "packages.python.py.inheritedPython"
    ''packages.python.py.inheritedPython.versions."0.8"''
    "packages.python.py.uses-python"
    ''packages.wasix.alternate."dot.name"''
    "packages.wasix.alternate.consumer"
    "packages.wasix.alternate.core"
    ''packages.wasix.alternate.core.versions."0.9"''
    "packages.wasix.alternate.limited"
    ''packages.wasix.default."dot.name"''
    "packages.wasix.default.ciNarrow"
    "packages.wasix.default.consumer"
    "packages.wasix.default.core"
    ''packages.wasix.default.core.versions."0.9"''
    "tests.artifacts.bundle.consumer.packaged"
    "tests.packages.native.consumer.probe"
    "tests.packages.native.core.probe"
    "tests.packages.wasix.alternate.consumer.probe"
    "tests.packages.wasix.alternate.core.probe"
    ''tests.packages.wasix.alternate.core.versions."0.9".probe''
    "tests.packages.wasix.default.consumer.probe"
    "tests.packages.wasix.default.core.probe"
    ''tests.packages.wasix.default.core.versions."0.9".probe''
  ];
  expectedSelectablePackageNames = [
    ''packages.native."dot.name"''
    "packages.native.broken"
    "packages.native.ciNarrow"
    "packages.native.consumer"
    "packages.native.core"
    "packages.native.limited"
    "packages.native.topOwned"
    "packages.native.uses-inherited"
    "packages.python.py.contextProof"
    "packages.python.py.corePython"
    "packages.python.py.inheritedPython"
    "packages.python.py.uses-python"
    ''packages.wasix.alternate."dot.name"''
    "packages.wasix.alternate.broken"
    "packages.wasix.alternate.ciNarrow"
    "packages.wasix.alternate.consumer"
    "packages.wasix.alternate.core"
    "packages.wasix.alternate.limited"
    "packages.wasix.alternate.topOwned"
    "packages.wasix.alternate.uses-inherited"
    ''packages.wasix.default."dot.name"''
    "packages.wasix.default.broken"
    "packages.wasix.default.ciNarrow"
    "packages.wasix.default.consumer"
    "packages.wasix.default.core"
    "packages.wasix.default.topOwned"
    "packages.wasix.default.uses-inherited"
  ];
  expectedTestNames = [
    "tests.artifacts.bundle.consumer.packaged"
    "tests.packages.native.consumer.probe"
    "tests.packages.native.core.probe"
    "tests.packages.wasix.alternate.consumer.probe"
    "tests.packages.wasix.alternate.core.probe"
    ''tests.packages.wasix.alternate.core.versions."0.9".probe''
    "tests.packages.wasix.default.consumer.probe"
    "tests.packages.wasix.default.core.probe"
    ''tests.packages.wasix.default.core.versions."0.9".probe''
  ];
in {
  pythonRepair = {
    expr = {
      idempotentPreBuild = historyRepairTwice.preBuild == historyRepairOnce.preBuild;
      idempotentPostPatch = historyRepairTwice.postPatch == historyRepairOnce.postPatch;
      inputs = map (input: input.name) historyRepairTwice.nativeBuildInputs;
      modules = historyRepairTwice.passthru.requiredPythonModules;
    };
    expected = {
      idempotentPreBuild = true;
      idempotentPostPatch = true;
      inputs = ["setuptools" "wheel"];
      modules = ["dependency"];
    };
  };

  builtInExtension = {
    expr = {
      inherit (extensionDeclaration) id;
      lanes = lib.attrNames extensionDeclaration.overlays;
      history = lib.attrNames extensionDeclaration.history;
      packagesDirectory = toString extensionDeclaration.overlays.packages.directory;
      legacyOverlayAbsent = !builtins.pathExists ../overlay;
      pythonHarnessPresent = builtins.pathExists ../harnesses/python.nix;
      legacyPythonHarnessAbsent = !builtins.pathExists ../python/wheels/test-lib.nix;
    };
    expected = {
      id = "wasinix";
      lanes = ["packages" "python"];
      history = ["python" "wasix"];
      packagesDirectory = toString ../overlays;
      legacyOverlayAbsent = true;
      pythonHarnessPresent = true;
      legacyPythonHarnessAbsent = true;
    };
  };

  packageUnits = {
    expr = {
      names = lib.attrNames loaded;
      existingInputs = map (package: package.name) loaded.existing.buildInputs;
      existingPolicy = loaded.existing.passthru.wasinix.test;
      inheritedProfiles = inheritedLoaded.dependency.passthru.wasix.supportedProfiles;
      replayedInheritedProfiles = replayedInherited.dependency.passthru.wasix.supportedProfiles;
      inheritedAbsentFromNative = !(nativeInherited ? dependency);
      replayNames = lib.attrNames loadedRaw.${projectLib.unitOverlaysAttr};
      fileUnitDirectory = (lib.findFirst (unit: unit.name == "existing") null discoveredUnits).directory;
      directoryUnitDirectory = toString (lib.findFirst (unit: unit.name == "family") null discoveredUnits).directory;
      bareUnitFails = !(force bareUnit).success;
      conflictingUnitsFail = !(force conflictingUnits).success;
      invalidShardedUnitsFail = !(force invalidShardedUnits).success;
      inherit topLevelPackageFiles;
      exposed = exposedUnits.dependency.name;
      missingExposureFails = !(force missingExposure).success;
      missingInheritedFails = !(force missingInherited).success;
      conflictingInheritedFails = !(force conflictingInherited).success;
      invalidInheritedFails = !(force invalidInherited).success;
      shardedNativeBase = shardedNative.alpha.name;
      shardedNativeIdentity = shardedNative.${projectLib.identityAttr}.beta.name;
      shardedNativeDoesNotRunWasix = !(shardedNative ? beta);
      shardedWasixBase = shardedWasixBase.alpha.name;
      shardedWasixAlpha = shardedWasix.alpha.variant;
      shardedWasixBeta = shardedWasix.beta.variant;
      wasmRename = lib.hasInfix "tool.wasm" (projectLib.wasmRename {wasmName = "tool";} (mkPackage {name = "tool";})).postInstall;
      buildEditSupersedesPyPI = pythonBuildEdit.passthru.wasinix.publication.supersedesPyPI;
      testEditSupersedesPyPI = pythonTestEdit.passthru.wasinix.publication.supersedesPyPI or false;
    };
    expected = {
      names = ["existing" "family-a" "family-b" "new"];
      existingInputs = ["dependency"];
      existingPolicy = true;
      inheritedProfiles = ["eh"];
      replayedInheritedProfiles = ["eh"];
      inheritedAbsentFromNative = true;
      replayNames = ["existing" "family-a" "family-b" "new"];
      fileUnitDirectory = null;
      directoryUnitDirectory = toString ./tests/units/family;
      bareUnitFails = true;
      conflictingUnitsFail = true;
      invalidShardedUnitsFail = true;
      topLevelPackageFiles = [];
      exposed = "dependency";
      missingExposureFails = true;
      missingInheritedFails = true;
      conflictingInheritedFails = true;
      invalidInheritedFails = true;
      shardedNativeBase = "alpha-base";
      shardedNativeIdentity = "beta-native";
      shardedNativeDoesNotRunWasix = true;
      shardedWasixBase = "alpha-base";
      shardedWasixAlpha = "wasix";
      shardedWasixBeta = "wasix";
      wasmRename = true;
      buildEditSupersedesPyPI = true;
      testEditSupersedesPyPI = false;
    };
  };

  provenance = {
    expr = {
      coreSource = core.owned.passthru.wasinix.source;
      delistedSource = core.plumbing.passthru.wasinix.source;
      extensionSource = extension.owned.passthru.wasinix.source;
      extensionLineage = extension.owned.passthru.wasinix.lineage;
      missingDeclarationFails = !(force (missingDeclaration {} core)).success;
      orphanDeclarationFails = !(force (orphanDeclaration {} {})).success;
      authoredDefinitionFails = !(force (authoredDefinition {} {})).success;
      changedDefinitionFails = !(force (changedDefinition {} core)).success;
    };
    expected = {
      coreSource = "wasinix";
      delistedSource = "wasinix";
      extensionSource = "my-project";
      extensionLineage = ["wasinix" "my-project"];
      missingDeclarationFails = true;
      orphanDeclarationFails = true;
      authoredDefinitionFails = true;
      changedDefinitionFails = true;
    };
  };

  pythonAggregate = {
    expr = {
      oldRuntime = (pythonRegistryFor "old").python3.name;
      oldWebc = (pythonRegistryFor "old").pythonCommand.artifact.name;
      newRuntime = (pythonRegistryFor "new").python3.name;
      newWebc = (pythonRegistryFor "new").pythonCommand.artifact.name;
      variants = lib.attrNames (pythonRegistryFor "new").pythonSets;
    };
    expected = {
      oldRuntime = "runtime-python-old";
      oldWebc = "webc-python-old";
      newRuntime = "runtime-python-new";
      newWebc = "webc-python-new";
      variants = ["new" "old"];
    };
  };

  definitions = {
    expr = {
      file = toString definitionProject.catalog.entries."packages.wasix.default.existing".definition.file;
      directory = toString definitionProject.catalog.entries."packages.wasix.default.family-a".definition.directory;
      historyFile = toString definitionProject.catalog.entries.${''packages.wasix.default.existing.versions."0.1"''}.definition.file;
      historyVendorPostPatch = definitionProject.packages.wasix.default.existing.versions."0.1".passthru.spec.vendorLayout.postPatch;
      historyVendorLockFileRemoved = !(definitionProject.packages.wasix.default.existing.versions."0.1".passthru.spec.vendorLayout ? lockFile);
      historyVendorMissingDefinitionFails =
        !(force (testHistoryLib.resolveHistoryLockFile {
          definition = null;
          label = "fixture.package 0.1";
          spec.vendorLayout.lockFile = "locks/0.1.lock";
        })).success;
      historyVendorConflictFails =
        !(force (testHistoryLib.resolveHistoryLockFile {
          definition.file = ./tests/units/existing.nix;
          label = "fixture.package 0.1";
          spec.vendorLayout = {
            lockFile = "locks/0.1.lock";
            postPatch = "false";
          };
        })).success;
      rawOverlay = project.catalog.entries."packages.wasix.default.core".definition;
    };
    expected = {
      file = toString ./tests/units/existing.nix;
      directory = toString ./tests/units/family;
      historyFile = toString ./tests/units/existing.nix;
      historyVendorPostPatch = "cp ${./tests/units/locks/0.1.lock} Cargo.lock";
      historyVendorLockFileRemoved = true;
      historyVendorMissingDefinitionFails = true;
      historyVendorConflictFails = true;
      rawOverlay = null;
    };
  };

  standaloneHistory = {
    expr = {
      current = replacementHistoryProject.packages.wasix.default.replacement.version;
      history = replacementHistoryProject.packages.wasix.default.replacement.versions."0.5".version;
    };
    expected = {
      current = "1.0";
      history = "0.5";
    };
  };

  behaviorChecks = {
    expr = {
      current = behaviorProject.tests."tests.artifacts.webc.behavior.packaged".name;
      history = behaviorProject.tests.${''tests.artifacts.webc.behavior.versions."0.9".packaged''}.name;
      currentCommand = map (package: package.name) behaviorProject.artifacts.webc.behavior.tests.packaged.passthru.harnessArgs.wasixPkgs;
      historyCommand = map (package: package.name) behaviorProject.artifacts.webc.behavior.versions."0.9".tests.packaged.passthru.harnessArgs.wasixPkgs;
      script = behaviorProject.artifacts.webc.behavior.tests.packaged.passthru.harnessArgs.script;
      historyTags = behaviorProject.ci.catalog.jobs.${''tests.artifacts.webc.behavior.versions."0.9".packaged''}.policy.ci.tags;
      definition = toString behaviorProject.catalog.entries."artifacts.webc.behavior".definition.directory;
      unpackaged = behaviorProject.tests."tests.packages.wasix.default.unpackaged.direct".name;
      unpackagedSubject = behaviorProject.ci.catalog.jobs."tests.packages.wasix.default.unpackaged.direct".subject;
      unpackagedArtifacts = behaviorProject.packages.wasix.default.unpackaged.artifacts;
      nonDerivationFails =
        !(force (projectLib.loadTestDirectory {
          context = {};
          dir = ./tests/invalid-tests/non-derivation;
        })).success;
      duplicateTestFails =
        !(force (projectLib.loadTestDirectory {
          context = {};
          dir = ./tests/invalid-tests/duplicate;
        })).success;
      duplicateCommandFails =
        !(force (fakeHarnesses.hostShell {
          script = "true";
          wasixCommands = [duplicateHarnessCommand duplicateHarnessCommand];
        })).success;
      wasixShellArgs = {
        inherit (fakeWasixShell.passthru.harnessArgs) forwardEnv wasmerArgs;
        nativePkgs = map (package: package.name) fakeWasixShell.passthru.harnessArgs.nativePkgs;
        wasixPkgs = map (package: package.name) fakeWasixShell.passthru.harnessArgs.wasixPkgs;
      };
      unknownRuntimeFails =
        !(force
          (fakeHarnesses.wasixShell {
            shell = fakeShellCommand;
            runtime.processes = true;
            script = "true";
          }).passthru.harnessArgs.wasmerArgs).success;
      invalidRuntimeFails =
        !(force
          (fakeHarnesses.wasixShell {
            shell = fakeShellCommand;
            runtime.network = "yes";
            script = "true";
          }).passthru.harnessArgs.wasmerArgs).success;
    };
    expected = {
      current = "host-shell-behavior-1.0";
      history = "host-shell-behavior-0.9";
      currentCommand = ["wasinix-command-behavior"];
      historyCommand = ["wasinix-command-behavior"];
      script = "behavior --version # native";
      historyTags = ["history-tests"];
      definition = toString ./tests/behavior-units/behavior;
      unpackaged = "host-shell-unpackaged-1.0";
      unpackagedSubject = "packages.wasix.default.unpackaged";
      unpackagedArtifacts = {};
      nonDerivationFails = true;
      duplicateTestFails = true;
      duplicateCommandFails = true;
      wasixShellArgs = {
        forwardEnv = ["FIXTURE"];
        nativePkgs = ["dependency"];
        wasixPkgs = ["wasinix-command-bash"];
        wasmerArgs = ["--net" "--enable-threads"];
      };
      unknownRuntimeFails = true;
      invalidRuntimeFails = true;
    };
  };

  wasmerProjection = {
    expr = {
      packageArtifact = wasmerProject.packages.wasix.default.auto.artifacts.pkg.name;
      webcArtifact = wasmerProject.artifacts.webc.auto.name;
      historyArtifact = wasmerProject.artifacts.webc.core.versions."0.9".name;
      servedVersions = wasmerProject.artifacts.pkg.core.passthru.servedVersions;
      commands = lib.attrNames wasmerProject.commands;
      packageCommands = lib.attrNames wasmerProject.packages.wasix.default.explicit.commands;
      autoCommand = wasmerProject.packages.wasix.default.auto.artifacts.webc.commands.auto.entrypoint;
      explicitCommand = wasmerProject.commands.second.entrypoint;
      historyCommands = lib.attrNames wasmerProject.artifacts.webc.core.versions."0.9".commands;
      relativeDependencyCommand = wasmerProject.packages.wasix.default.explicit.artifacts.webc.commands.dependency.name;
      localCommandsAreNotGlobal = !(wasmerProject.commands ? dependency) && !(wasmerProject.commands ? local);
      commandAddresses = builtins.filter (name: lib.hasPrefix "commands." name) (lib.attrNames wasmerProject.catalog.entries);
      dataCommands = wasmerProject.packages.wasix.default.data.artifacts.webc.commands;
      unshippedArtifacts = wasmerProject.packages.wasix.default.unshipped.artifacts;
      alternateArtifacts = wasmerProject.packages.wasix.alternate.auto.artifacts;
      artifactKind = wasmerProject.catalog.entries."artifacts.webc.auto".kind;
      artifactAliases = wasmerProject.ci.catalog.jobs."artifacts.webc.auto".policy.aliases;
      unnamedCommandFails = !(force unnamedWasmerCommandProject.artifacts).success;
      invalidCommandsFails = !(force invalidWasmerCommandsProject.artifacts).success;
      duplicateCommandFails = !(force duplicateWasmerCommandProject.artifacts).success;
    };
    expected = {
      packageArtifact = "pkg-auto-default";
      webcArtifact = "webc-auto-default";
      historyArtifact = "webc-core-0.9";
      servedVersions = ["core" "0.9"];
      commands = ["auto" "core" "first" "second"];
      packageCommands = ["dependency" "first" "local" "second"];
      autoCommand = "launch";
      explicitCommand = "second";
      historyCommands = ["core"];
      relativeDependencyCommand = "dependency";
      localCommandsAreNotGlobal = true;
      commandAddresses = [
        "commands.auto"
        "commands.core"
        ''commands.core.versions."0.9"''
        "commands.dependency.from.explicit"
        "commands.first"
        "commands.local.from.explicit"
        "commands.second"
      ];
      dataCommands = {};
      unshippedArtifacts = {};
      alternateArtifacts = {};
      artifactKind = "artifact";
      artifactAliases = ["artifacts.webc.automatic"];
      unnamedCommandFails = true;
      invalidCommandsFails = true;
      duplicateCommandFails = true;
    };
  };

  structuredProject = {
    expr = {
      inherit (project) schemaVersion;
      nativeNames = lib.attrNames project.packages.native;
      nativeInterfaceName = project.packages.native.core.profiles.default.package.name;
      wasixViewNames = lib.attrNames project.packages.wasix;
      topLevelPreferredAbsent = !(project.packages ? preferred);
      defaultNames = lib.attrNames project.packages.wasix.default;
      alternateNames = lib.attrNames project.packages.wasix.alternate;
      coreSource = project.packages.wasix.default.core.passthru.wasinix.source;
      coreLineage = project.packages.wasix.default.core.passthru.wasinix.lineage;
      preferredProfile = project.packages.wasix.preferred.core.name;
      limitedPreferred = project.packages.wasix.preferred.limited.name;
      consumerName = project.packages.wasix.alternate.consumer.name;
      inheritedDependencyName = project.packages.wasix.default.uses-inherited.name;
      focusedHelper = project.packages.wasix.default.uses-inherited.passthru.usedFocusedHelper;
      preferredPackageSetName = project.packages.wasix.default.uses-inherited.passthru.preferredPackageSetName;
      topLevelPreferredPackageSetAbsent = project.packages.wasix.default.uses-inherited.passthru.topLevelPreferredPackageSetAbsent;
      runnerContextName = project.packages.wasix.default.uses-inherited.passthru.runnerContextName;
      maintainerLogin = project.packages.wasix.default.uses-inherited.passthru.maintainerLogin;
      reviewerLogins = project.packages.wasix.default.uses-inherited.passthru.reviewerLogins;
      ownership = project.ownership."unit-consumer";
      runnerName = project.runners.rawWasm.unbound.name;
      pythonHarnessAvailable = project.harnesses ? python;
      ifdProbe = project.probes.ifd.passthru.text;
      profileNames = project.packages.wasix.default.uses-inherited.passthru.profileNames;
      pythonNames = lib.attrNames project.packages.python.py;
      preferredPythonName = project.packages.python.preferred.corePython.name;
      pythonSource = project.packages.python.py.uses-python.passthru.wasinix.source;
      pythonContextName = project.packages.python.py.contextProof.name;
      repairedPythonModules = pythonRepairProject.packages.python.py.repairPython.passthru.requiredPythonModules;
      wasixHistoryVersion = project.packages.wasix.default.core.versions."0.9".version;
      preferredHistoryVersion = project.packages.wasix.preferred.core.versions."0.9".version;
      pythonHistoryVersion = project.packages.python.py.inheritedPython.versions."0.8".version;
      historyDependencyVersion = project.packages.python.py.inheritedPython.versions."0.8".passthru.wasinix.historyDependency;
      currentTransformed = project.packages.wasix.default.core.passthru.transformed;
      historyTransformed = project.packages.wasix.default.core.versions."0.9".passthru.transformed;
      packageArtifactName = project.packages.wasix.default.consumer.artifacts.bundle.name;
      globalArtifactName = project.artifacts.bundle.consumer.name;
      commandName = project.commands.consumer.name;
      artifactTestName = project.tests."tests.artifacts.bundle.consumer.packaged".name;
      artifactTestSubject = project.ci.catalog.jobs."tests.artifacts.bundle.consumer.packaged".subject;
      historyTags = project.ci.catalog.jobs.${''packages.wasix.default.core.versions."0.9"''}.policy.ci.tags;
      historyTestTags = project.ci.catalog.jobs.${''tests.packages.wasix.default.core.versions."0.9".probe''}.policy.ci.tags;
      ciSources = project.ci.sources;
      ciJobNames = lib.attrNames project.ci.jobs;
      catalogJobNames = lib.attrNames project.ci.catalog.jobs;
      selectorNames = lib.attrNames project.ci.catalog.selectors.sets;
      selectorGroupNames = lib.attrNames project.ci.catalog.selectors.groups;
      selectorSourceNames = lib.attrNames project.ci.catalog.selectors.sources;
      sourceSelectorCoversJobs = project.ci.catalog.selectors.sources.consumer == lib.attrNames project.ci.jobs;
      selectablePackageNames = lib.attrNames project.ci.catalog.packages;
      selectorsCoverJobs =
        lib.sort builtins.lessThan (lib.unique (lib.concatLists (lib.attrValues project.ci.catalog.selectors.sets)))
        == lib.sort builtins.lessThan (lib.attrNames project.ci.jobs);
      ciPackageIsRaw = !(project.ci.jobs."packages.wasix.default.consumer" ? artifacts);
      ciArtifactIsRaw = !(project.ci.jobs."artifacts.bundle.consumer" ? tests);
      brokenCiAbsent = !(builtins.hasAttr "packages.wasix.default.broken" project.ci.jobs);
      testNames = lib.attrNames project.tests;
      testSubject = project.ci.catalog.jobs."tests.packages.wasix.default.consumer.probe".subject;
      testContextName = project.tests."tests.packages.wasix.default.consumer.probe".name;
      unknownCiSourceFails = !(force unknownCiSource).success;
      duplicateExtensionFails = !(force duplicateExtension).success;
      invalidMaintainerOwnershipFails = !(force invalidMaintainerOwnership).success;
      invalidTeamOwnershipFails = !(force invalidTeamOwnership).success;
      nonPackageOverlayFails = !(force nonPackageOverlayProject).success;
      aliasCollisionFails = !(force aliasCollisionProject).success;
      duplicateProjectionFails = !(force duplicateProjectionProject.tests).success;
      duplicateArtifactFails = !(force duplicateArtifactProject.artifacts).success;
      duplicateCommandFails = !(force duplicateCommandProject.commands).success;
      typedNamespacesMerge =
        (force {
          artifact = typedNamespaceProject.artifacts.same.consumer.name;
          test = typedNamespaceProject.tests."tests.packages.wasix.default.consumer.same".name;
        }).success;
      historyProjections = {
        current = historyProjectionProject.artifacts.retained.core.name;
        history = historyProjectionProject.artifacts.retained.core.versions."0.9".name;
        test = historyProjectionProject.tests.${''tests.artifacts.retained.core.versions."0.9".inspect''}.name;
      };
      aggregateProjection = {
        artifact = aggregateProjectionProject.artifacts.aggregate.fixture.name;
        subjects = aggregateProjectionProject.catalog.entries."artifacts.aggregate.fixture".subjects;
        packageSubjects = aggregateProjectionProject.catalog.entries."artifacts.aggregate.fixture".packageSubjects;
        test = aggregateProjectionProject.tests."tests.artifacts.aggregate.fixture.inspect".name;
        testPackageSubjects = aggregateProjectionProject.catalog.entries."tests.artifacts.aggregate.fixture.inspect".packageSubjects;
        ciIncludesArtifact = aggregateProjectionProject.ci.jobs ? "artifacts.aggregate.fixture";
        ciIncludesTest = aggregateProjectionProject.ci.jobs ? "tests.artifacts.aggregate.fixture.inspect";
      };
      duplicateAggregateFails = !(force duplicateAggregateProject.artifacts).success;
      unknownAggregateSourceFails = !(force unknownAggregateSourceProject.artifacts).success;
      invalidAggregateSubjectsFail = !(force invalidAggregateSubjectsProject.catalog).success;
      malformedAggregateSubjectsFail = !(force malformedAggregateSubjectsProject.catalog).success;
      invalidProjectionFails = !(force invalidProjectionProject.tests).success;
      invalidArtifactFails = !(force invalidArtifactProject.artifacts).success;
      invalidCommandFails = !(force invalidCommandProject.commands).success;
      invalidNamespaceFails = !(force invalidNamespaceProject.catalog).success;
      invalidNamespaceShapeFails = !(force invalidNamespaceShapeProject.catalog).success;
      invalidResultFails = !(force invalidResultProject.catalog).success;
      invalidRuleFails = !(force invalidRuleProject).success;
      variantShapeFails = !(force variantShapeProject).success;
      staleHistoryFails = !(force staleHistoryProject).success;
      invalidProfileFails = !(force invalidProfileProject).success;
      invalidCiProfileFails = !(force invalidCiProfileProject.ci).success;
      invalidNativeInterfaceFails = !(force invalidNativeInterfaceProject).success;
      emptyProjectSource = emptyProject.packages.native.core.passthru.wasinix.source;
      perProjectRule = emptyProject.tests."tests.packages.wasix.default.core.per-project".name;
      projectTestName = projectTestProject.tests."tests.project.format".name;
      projectTestSerializable = !(projectTestProject.ci.catalog.jobs."tests.project.format" ? check);
      postUpdateCommand = repositoryHooks."packages.native.command";
      postUpdateSync = repositoryHooks."packages.native.sync";
      updateScriptNames = lib.attrNames repositoryScripts;
      updateOwnership = repositoryScripts."packages.native.ownedUpdate".ownership;
      updateSnapshot = {
        inherit (repository.updates.snapshot) defaultUpdateOwnership schemaVersion servedVersions;
        hookNames = lib.attrNames repository.updates.snapshot.postUpdateHooks;
        scriptNames = lib.attrNames repository.updates.snapshot.updateScripts;
      };
    };
    expected = {
      schemaVersion = 1;
      nativeNames = ["broken" "ciNarrow" "consumer" "core" "dot.name" "limited" "topOwned" "uses-inherited"];
      nativeInterfaceName = "core";
      wasixViewNames = ["alternate" "default" "preferred"];
      topLevelPreferredAbsent = true;
      defaultNames = ["broken" "ciNarrow" "consumer" "core" "dot.name" "topOwned" "uses-inherited"];
      alternateNames = ["broken" "ciNarrow" "consumer" "core" "dot.name" "limited" "topOwned" "uses-inherited"];
      coreSource = "consumer";
      coreLineage = ["wasinix" "consumer"];
      preferredProfile = "core";
      limitedPreferred = "limited-alternate";
      consumerName = "consumer-alternate";
      inheritedDependencyName = "uses-inherited";
      focusedHelper = true;
      preferredPackageSetName = "core";
      topLevelPreferredPackageSetAbsent = true;
      runnerContextName = "raw-wasm-unbound";
      maintainerLogin = "jane-doe";
      reviewerLogins = ["jane-doe"];
      ownership = {
        maintainers.janeDoe.github = "jane-doe";
        teams.core = [];
        teams.php = [{github = "jane-doe";}];
      };
      updateOwnership = {
        assignees = [{github = "jane-doe";}];
        reviewers = [{github = "jane-doe";}];
      };
      runnerName = "raw-wasm-unbound";
      pythonHarnessAvailable = true;
      ifdProbe = "ok";
      profileNames = ["alternate" "default"];
      pythonNames = ["contextProof" "corePython" "inheritedPython" "uses-python"];
      preferredPythonName = "core-python";
      pythonSource = "consumer";
      pythonContextName = "top-owned-";
      repairedPythonModules = ["dependency"];
      wasixHistoryVersion = "0.9";
      preferredHistoryVersion = "0.9";
      pythonHistoryVersion = "0.8";
      historyDependencyVersion = "0.9";
      currentTransformed = true;
      historyTransformed = true;
      packageArtifactName = "consumer-bundle";
      globalArtifactName = "consumer-bundle";
      commandName = "consumer";
      artifactTestName = "packaged-consumer-bundle-consumer";
      artifactTestSubject = "artifacts.bundle.consumer";
      historyTags = ["history-tests"];
      historyTestTags = ["history-tests"];
      ciPackageIsRaw = true;
      ciArtifactIsRaw = true;
      ciSources = ["consumer"];
      ciJobNames = expectedCiJobNames;
      catalogJobNames = expectedCiJobNames;
      selectorNames = ["core" "packages" "python"];
      selectorGroupNames = ["fixture"];
      selectorSourceNames = ["consumer"];
      sourceSelectorCoversJobs = true;
      selectablePackageNames = expectedSelectablePackageNames;
      selectorsCoverJobs = true;
      brokenCiAbsent = true;
      testNames = expectedTestNames;
      testSubject = "packages.wasix.default.consumer";
      testContextName = "probe-consumer-default-0.9";
      unknownCiSourceFails = true;
      duplicateExtensionFails = true;
      invalidMaintainerOwnershipFails = true;
      invalidTeamOwnershipFails = true;
      nonPackageOverlayFails = true;
      aliasCollisionFails = true;
      duplicateProjectionFails = true;
      duplicateArtifactFails = true;
      duplicateCommandFails = true;
      typedNamespacesMerge = true;
      historyProjections = {
        current = "retained-core";
        history = "retained-0.9";
        test = "inspect-retained-0.9";
      };
      aggregateProjection = {
        artifact = "aggregate-consumer-default-py";
        subjects = ["artifacts.bundle.consumer"];
        packageSubjects = ["packages.wasix.default.consumer"];
        test = "inspect-aggregate-consumer-default-py";
        testPackageSubjects = ["packages.wasix.default.consumer"];
        ciIncludesArtifact = true;
        ciIncludesTest = true;
      };
      duplicateAggregateFails = true;
      unknownAggregateSourceFails = true;
      invalidAggregateSubjectsFail = true;
      malformedAggregateSubjectsFail = true;
      invalidProjectionFails = true;
      invalidArtifactFails = true;
      invalidCommandFails = true;
      invalidNamespaceFails = true;
      invalidNamespaceShapeFails = true;
      invalidResultFails = true;
      invalidRuleFails = true;
      variantShapeFails = true;
      staleHistoryFails = true;
      invalidProfileFails = true;
      invalidCiProfileFails = true;
      invalidNativeInterfaceFails = true;
      emptyProjectSource = "empty";
      perProjectRule = "per-project";
      projectTestName = "format";
      projectTestSerializable = true;
      postUpdateCommand = {
        action = {
          kind = "command";
          command = ["./hook"];
          commandDrvPaths = [];
        };
        version = "1";
      };
      postUpdateSync = {
        action = {
          kind = "syncAttrList";
          input = "nixpkgs";
          attrPath = "legacyPackages.\${system}";
          match = "^icu([0-9]+)$";
          capture = 1;
          probe = "version";
          sort = "numeric";
          destination = "versions.nix";
        };
        version = "2";
      };
      updateScriptNames = ["packages.native.ownedUpdate" "packages.wasix.preferred.cli"];
      updateSnapshot = {
        schemaVersion = 2;
        defaultUpdateOwnership = {
          assignees = [];
          reviewers = [];
        };
        servedVersions = {
          cli.cli = {
            version = "1";
            history_spec = "packages.wasix.cli";
            retention = "major";
          };
          wheel.demo = {
            version = "3";
            history_spec = "packages.python.demo";
            retention = "minor";
          };
        };
        hookNames = ["packages.native.command" "packages.native.sync"];
        scriptNames = ["packages.native.ownedUpdate" "packages.wasix.preferred.cli"];
      };
    };
  };
}
