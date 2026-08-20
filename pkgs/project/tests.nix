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

  dependency = mkPackage {name = "dependency";};
  previous = mkPackage {
    name = "existing";
    buildInputs = [];
  };
  newRecipe = mkPackage {name = "new";};
  familyA = mkPackage {name = "family-a";};
  familyB = mkPackage {name = "family-b";};
  final = {
    inherit dependency newRecipe familyA familyB;
  };
  prev = {
    existing = previous;
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
  loaded = builtins.removeAttrs loadedRaw [projectLib.unitOverlaysAttr];
  discoveredUnits = projectLib.discoverUnits ./tests/units;
  bareUnit =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/invalid-units;
    }
    final
    prev;

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
    overlay = _final: previous: {owned = previous.owned;};
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
        overrideScope = overlay: mkPythonSet (overlays ++ [overlay]);
      }
      overlays);

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
      overlays.shared = _final: _previous: {
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
        packageSet = mkPythonSet [];
      };
    };
    nativePackageInterfacesFor = {project, ...}: {
      core.profiles.default.package = project.packages.wasix.default.core;
    };
    runnersFor = _args: {
      rawWasm.unbound = mkPackage {name = "raw-wasm-unbound";};
    };
    rebasePackage = version: _spec: package:
      package.overrideAttrs (_: {
        inherit version;
        name = "${package.name}-${version}";
      });
  };
  fakeWebcIdent = package: {
    name = package.passthru.wasmer.name or package.pname or package.name;
    baseVersion = toString (package.version or package.name);
  };
  fakeMakeWasmerPackage = {
    package,
    servedVersions,
  }: let
    webc = mkPackage {
      name = "webc-${package.name}";
      shim = mkPackage {name = "shim-${package.name}";};
    };
  in
    mkPackage {
      name = "pkg-${package.name}";
      inherit webc;
      passthru = {inherit servedVersions;};
    };
  wasmerProjectionRules = import ../artifacts/wasmer.nix {
    inherit lib;
    makeWasmerPackage = fakeMakeWasmerPackage;
    webcIdent = fakeWebcIdent;
  };
  behaviorProjectionRules = import ../checks/behavior.nix {
    inherit lib projectLib;
  };
  fakeTestLib = {
    defaultForwardEnv = ["HOME"];
    defaultWasixTimeout = 600;
    mkWasixRun = args:
      mkPackage {
        name = "host-shell-${args.name}";
        passthru.harnessArgs = args;
      };
  };
  fakeHarnesses = import ../harnesses {
    inherit lib;
    pkgs.runCommand = name: attrs: script:
      mkPackage {
        inherit name script;
        passthru.runCommandAttrs = attrs;
      };
    testLib = fakeTestLib;
  };
  duplicateHarnessCommand = {
    name = "duplicate";
    entrypoint = "duplicate";
    artifact = mkPackage {
      name = "duplicate-webc";
      shim = mkPackage {name = "duplicate-shim";};
    };
  };
  projectApi = import ./default.nix (projectApiArgs
    // {
      projectionRules = {
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
      behavior = mkPackage {
        name = "behavior";
        version = "1.0";
      };
      existing = previous;
      inherited = mkPackage {name = "inherited";};
      profile = args.crossSystem.wasinixProfile or "native";
    };
  in
    lib.fix (final: builtins.foldl' (previous: overlay: previous // overlay final previous) base args.overlays);
  consumerExtension = {
    id = "consumer";
    history = {
      wasix = ./tests/wasix-history.json;
      python = ./tests/python-history.json;
    };
    overlays = {
      wasix = final: previous: {
        core = projectLib.extendPackage previous.core {
          passthru.wasinix.overrides = "wasinix";
          passthru.wasinix.checks.probe = true;
          passthru.wasinix.ci.profiles = ["default" "alternate"];
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
        helper = "not-a-package";
        plumbing = mkPackage {
          name = "plumbing";
          passthru.wasinix.catalog = false;
        };
      };
      python =
        (projectApi.loadPackageOverlays {
          python = ./tests/python-units;
        }).python;
    };
  };
  unitExtension = {
    id = "unit-consumer";
    overlays = projectApi.loadPackageOverlays {
      wasix = ./tests/project-units;
    };
  };
  definitionExtension = {
    id = "definition-consumer";
    history.wasix = ./tests/unit-history.json;
    overlays = projectApi.loadPackageOverlays {
      wasix = ./tests/units;
    };
  };
  pythonContextExtension = {
    id = "python-context";
    overlays = {
      wasix = _final: _previous: {
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
  project = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [consumerExtension unitExtension pythonContextExtension];
    ci.sources = ["consumer"];
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
  wasmerProjectApi = import ./default.nix (projectApiArgs // {projectionRules = wasmerProjectionRules;});
  behaviorProjectApi = import ./default.nix (projectApiArgs
    // {
      harnessesFor = _args: fakeHarnesses;
      projectionRules = wasmerProjectionRules // behaviorProjectionRules;
    });
  wasmerExtension = {
    id = "wasmer-fixture";
    history.wasix = ./tests/wasix-history.json;
    overlays.wasix = final: previous: {
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
          wasinix.shipped = true;
        };
      };
      explicit = mkPackage {
        name = "explicit-${final.profile}";
        version = "2.0";
        passthru = {
          wasmer.commands = [
            {name = "first";}
            {name = "second";}
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
      wasix = ./tests/behavior-units;
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
          overlays.wasix = _final: _previous: {
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
  variantShapeProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "variant-shape";
        overlays.wasix = _final: previous:
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
  invalidProfileProject = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [
      {
        id = "invalid-profile";
        overlays.wasix = _final: _previous: {
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
        overlays.wasix = _final: _previous: {
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
    (import ./default.nix (projectApiArgs // {inherit projectionRules;})).mkProject {
      system = "test-system";
      importNixpkgs = fakeImportNixpkgs;
      extensions = [consumerExtension];
    };
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
  extensionDeclaration = import ../extension.nix {inherit (projectLib) loadPackageOverlays;};
in {
  builtInExtension = {
    expr = {
      inherit (extensionDeclaration) id;
      lanes = lib.attrNames extensionDeclaration.overlays;
      history = lib.attrNames extensionDeclaration.history;
      sharedDirectory = toString extensionDeclaration.overlays.shared.directory;
    };
    expected = {
      id = "wasinix";
      lanes = ["native" "python" "shared" "wasix"];
      history = ["python" "wasix"];
      sharedDirectory = toString ../shared;
    };
  };

  packageUnits = {
    expr = {
      names = lib.attrNames loaded;
      existingInputs = map (package: package.name) loaded.existing.buildInputs;
      existingPolicy = loaded.existing.passthru.wasinix.test;
      replayNames = lib.attrNames loadedRaw.${projectLib.unitOverlaysAttr};
      fileUnitDirectory = (lib.findFirst (unit: unit.name == "existing") null discoveredUnits).directory;
      directoryUnitDirectory = toString (lib.findFirst (unit: unit.name == "family") null discoveredUnits).directory;
      bareUnitFails = !(force bareUnit).success;
      wasmRename = lib.hasInfix "tool.wasm" ((projectLib.wasmRename {wasmName = "tool";} (mkPackage {name = "tool";})).postInstall);
    };
    expected = {
      names = ["existing" "family-a" "family-b" "new"];
      existingInputs = ["dependency"];
      existingPolicy = true;
      replayNames = ["existing" "family-a" "family-b" "new"];
      fileUnitDirectory = null;
      directoryUnitDirectory = toString ./tests/units/family;
      bareUnitFails = true;
      wasmRename = true;
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

  definitions = {
    expr = {
      file = toString definitionProject.catalog.entries."packages.wasix.default.existing".definition.file;
      directory = toString definitionProject.catalog.entries."packages.wasix.default.family-a".definition.directory;
      historyFile = toString definitionProject.catalog.entries.${''packages.wasix.default.existing.versions["0.1"]''}.definition.file;
      rawOverlay = project.catalog.entries."packages.wasix.default.core".definition;
    };
    expected = {
      file = toString ./tests/units/existing.nix;
      directory = toString ./tests/units/family;
      historyFile = toString ./tests/units/existing.nix;
      rawOverlay = null;
    };
  };

  behaviorChecks = {
    expr = {
      current = behaviorProject.tests."tests.artifacts.webc.behavior.packaged".name;
      history = behaviorProject.tests.${''tests.artifacts.webc.behavior.versions["0.9"].packaged''}.name;
      currentCommand = map (package: package.name) behaviorProject.artifacts.webc.behavior.tests.packaged.passthru.harnessArgs.wasixPkgs;
      historyCommand = map (package: package.name) behaviorProject.artifacts.webc.behavior.versions."0.9".tests.packaged.passthru.harnessArgs.wasixPkgs;
      script = behaviorProject.artifacts.webc.behavior.tests.packaged.passthru.harnessArgs.script;
      historyTags = behaviorProject.ci.catalog.jobs.${''tests.artifacts.webc.behavior.versions["0.9"].packaged''}.policy.ci.tags;
      definition = toString behaviorProject.catalog.entries."artifacts.webc.behavior".definition.directory;
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
    };
    expected = {
      current = "host-shell-behavior-1.0";
      history = "host-shell-behavior-0.9";
      currentCommand = ["wasinix-command-behavior"];
      historyCommand = ["wasinix-command-behavior"];
      script = "behavior --version # native";
      historyTags = ["history-tests"];
      definition = toString ./tests/behavior-units/behavior;
      nonDerivationFails = true;
      duplicateTestFails = true;
      duplicateCommandFails = true;
    };
  };

  wasmerProjection = {
    expr = {
      packageArtifact = wasmerProject.packages.wasix.default.auto.artifacts.pkg.name;
      webcArtifact = wasmerProject.artifacts.webc.auto.name;
      historyArtifact = wasmerProject.artifacts.webc.core.versions."0.9".name;
      servedVersions = wasmerProject.artifacts.pkg.core.passthru.servedVersions;
      commands = lib.attrNames wasmerProject.commands;
      autoCommand = wasmerProject.packages.wasix.default.auto.artifacts.webc.commands.auto.entrypoint;
      explicitCommand = wasmerProject.commands.second.entrypoint;
      historyCommands = lib.attrNames wasmerProject.artifacts.webc.core.versions."0.9".commands;
      commandAddresses = builtins.filter (name: lib.hasPrefix "commands." name) (lib.attrNames wasmerProject.catalog.entries);
      dataCommands = wasmerProject.packages.wasix.default.data.artifacts.webc.commands;
      unshippedArtifacts = wasmerProject.packages.wasix.default.unshipped.artifacts;
      alternateArtifacts = wasmerProject.packages.wasix.alternate.auto.artifacts;
      artifactKind = wasmerProject.catalog.entries."artifacts.webc.auto".kind;
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
      autoCommand = "launch";
      explicitCommand = "second";
      historyCommands = ["core"];
      commandAddresses = [
        "commands.auto"
        "commands.core"
        ''commands.core.versions["0.9"]''
        "commands.first"
        "commands.second"
      ];
      dataCommands = {};
      unshippedArtifacts = {};
      alternateArtifacts = {};
      artifactKind = "artifact";
      unnamedCommandFails = true;
      invalidCommandsFails = true;
      duplicateCommandFails = true;
    };
  };

  structuredProject = {
    expr = {
      schemaVersion = project.schemaVersion;
      nativeNames = lib.attrNames project.packages.native;
      nativeInterfaceName = project.packages.native.core.profiles.default.package.name;
      defaultNames = lib.attrNames project.packages.wasix.default;
      alternateNames = lib.attrNames project.packages.wasix.alternate;
      coreSource = project.packages.wasix.default.core.passthru.wasinix.source;
      coreLineage = project.packages.wasix.default.core.passthru.wasinix.lineage;
      preferredProfile = project.packages.preferred.core.name;
      limitedPreferred = project.packages.preferred.limited.name;
      consumerName = project.packages.wasix.alternate.consumer.name;
      inheritedDependencyName = project.packages.wasix.default.uses-inherited.name;
      focusedHelper = project.packages.wasix.default.uses-inherited.passthru.usedFocusedHelper;
      runnerContextName = project.packages.wasix.default.uses-inherited.passthru.runnerContextName;
      runnerName = project.runners.rawWasm.unbound.name;
      pythonNames = lib.attrNames project.packages.python.py;
      pythonSource = project.packages.python.py.uses-python.passthru.wasinix.source;
      pythonContextName = project.packages.python.py.contextProof.name;
      repairedPythonModules = pythonRepairProject.packages.python.py.repairPython.passthru.requiredPythonModules;
      wasixHistoryVersion = project.packages.wasix.default.core.versions."0.9".version;
      preferredHistoryVersion = project.packages.preferred.core.versions."0.9".version;
      pythonHistoryVersion = project.packages.python.py.inheritedPython.versions."0.8".version;
      historyDependencyVersion = project.packages.python.py.inheritedPython.versions."0.8".passthru.wasinix.historyDependency;
      packageArtifactName = project.packages.wasix.default.consumer.artifacts.bundle.name;
      globalArtifactName = project.artifacts.bundle.consumer.name;
      commandName = project.commands.consumer.name;
      artifactTestName = project.tests."tests.artifacts.bundle.consumer.packaged".name;
      artifactTestSubject = project.ci.catalog.jobs."tests.artifacts.bundle.consumer.packaged".subject;
      historyTags = project.ci.catalog.jobs."packages.wasix.default.core.versions[\"0.9\"]".policy.ci.tags;
      historyTestTags = project.ci.catalog.jobs."tests.packages.wasix.default.core.versions[\"0.9\"].probe".policy.ci.tags;
      ciSources = project.ci.sources;
      ciJobNames = lib.attrNames project.ci.jobs;
      catalogJobNames = lib.attrNames project.ci.catalog.jobs;
      testNames = lib.attrNames project.tests;
      testSubject = project.ci.catalog.jobs."tests.packages.wasix.default.consumer.probe".subject;
      testContextName = project.tests."tests.packages.wasix.default.consumer.probe".name;
      unknownCiSourceFails = !(force unknownCiSource).success;
      duplicateExtensionFails = !(force duplicateExtension).success;
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
        test = historyProjectionProject.tests.${''tests.artifacts.retained.core.versions["0.9"].inspect''}.name;
      };
      invalidProjectionFails = !(force invalidProjectionProject.tests).success;
      invalidArtifactFails = !(force invalidArtifactProject.artifacts).success;
      invalidCommandFails = !(force invalidCommandProject.commands).success;
      invalidNamespaceFails = !(force invalidNamespaceProject.catalog).success;
      invalidNamespaceShapeFails = !(force invalidNamespaceShapeProject.catalog).success;
      invalidResultFails = !(force invalidResultProject.catalog).success;
      variantShapeFails = !(force variantShapeProject).success;
      staleHistoryFails = !(force staleHistoryProject).success;
      invalidProfileFails = !(force invalidProfileProject).success;
      invalidCiProfileFails = !(force invalidCiProfileProject.ci).success;
      invalidNativeInterfaceFails = !(force invalidNativeInterfaceProject).success;
    };
    expected = {
      schemaVersion = 1;
      nativeNames = ["core"];
      nativeInterfaceName = "core";
      defaultNames = ["ciNarrow" "consumer" "core" "dot.name" "topOwned" "uses-inherited"];
      alternateNames = ["ciNarrow" "consumer" "core" "dot.name" "limited" "topOwned" "uses-inherited"];
      coreSource = "consumer";
      coreLineage = ["wasinix" "consumer"];
      preferredProfile = "core";
      limitedPreferred = "limited-alternate";
      consumerName = "consumer-alternate";
      inheritedDependencyName = "uses-inherited";
      focusedHelper = true;
      runnerContextName = "raw-wasm-unbound";
      runnerName = "raw-wasm-unbound";
      pythonNames = ["contextProof" "corePython" "inheritedPython" "uses-python"];
      pythonSource = "consumer";
      pythonContextName = "top-owned-";
      repairedPythonModules = ["dependency"];
      wasixHistoryVersion = "0.9";
      preferredHistoryVersion = "0.9";
      pythonHistoryVersion = "0.8";
      historyDependencyVersion = "0.9";
      packageArtifactName = "consumer-bundle";
      globalArtifactName = "consumer-bundle";
      commandName = "consumer";
      artifactTestName = "packaged-consumer-bundle-consumer";
      artifactTestSubject = "artifacts.bundle.consumer";
      historyTags = ["history-tests"];
      historyTestTags = ["history-tests"];
      ciSources = ["consumer"];
      ciJobNames = [
        "artifacts.bundle.consumer"
        "packages.python.py.inheritedPython"
        ''packages.python.py.inheritedPython.versions["0.8"]''
        "packages.python.py.uses-python"
        "packages.wasix.alternate.consumer"
        "packages.wasix.alternate.core"
        ''packages.wasix.alternate.core.versions["0.9"]''
        "packages.wasix.alternate.limited"
        ''packages.wasix.alternate["dot.name"]''
        "packages.wasix.default.ciNarrow"
        "packages.wasix.default.consumer"
        "packages.wasix.default.core"
        ''packages.wasix.default.core.versions["0.9"]''
        ''packages.wasix.default["dot.name"]''
        "tests.artifacts.bundle.consumer.packaged"
        "tests.packages.wasix.alternate.consumer.probe"
        "tests.packages.wasix.alternate.core.probe"
        ''tests.packages.wasix.alternate.core.versions["0.9"].probe''
        "tests.packages.wasix.default.consumer.probe"
        "tests.packages.wasix.default.core.probe"
        ''tests.packages.wasix.default.core.versions["0.9"].probe''
      ];
      catalogJobNames = [
        "artifacts.bundle.consumer"
        "packages.python.py.inheritedPython"
        ''packages.python.py.inheritedPython.versions["0.8"]''
        "packages.python.py.uses-python"
        "packages.wasix.alternate.consumer"
        "packages.wasix.alternate.core"
        ''packages.wasix.alternate.core.versions["0.9"]''
        "packages.wasix.alternate.limited"
        ''packages.wasix.alternate["dot.name"]''
        "packages.wasix.default.ciNarrow"
        "packages.wasix.default.consumer"
        "packages.wasix.default.core"
        ''packages.wasix.default.core.versions["0.9"]''
        ''packages.wasix.default["dot.name"]''
        "tests.artifacts.bundle.consumer.packaged"
        "tests.packages.wasix.alternate.consumer.probe"
        "tests.packages.wasix.alternate.core.probe"
        ''tests.packages.wasix.alternate.core.versions["0.9"].probe''
        "tests.packages.wasix.default.consumer.probe"
        "tests.packages.wasix.default.core.probe"
        ''tests.packages.wasix.default.core.versions["0.9"].probe''
      ];
      testNames = [
        "tests.artifacts.bundle.consumer.packaged"
        "tests.packages.wasix.alternate.consumer.probe"
        "tests.packages.wasix.alternate.core.probe"
        ''tests.packages.wasix.alternate.core.versions["0.9"].probe''
        "tests.packages.wasix.default.consumer.probe"
        "tests.packages.wasix.default.core.probe"
        ''tests.packages.wasix.default.core.versions["0.9"].probe''
      ];
      testSubject = "packages.wasix.default.consumer";
      testContextName = "probe-consumer-default-0.9";
      unknownCiSourceFails = true;
      duplicateExtensionFails = true;
      duplicateProjectionFails = true;
      duplicateArtifactFails = true;
      duplicateCommandFails = true;
      typedNamespacesMerge = true;
      historyProjections = {
        current = "retained-core";
        history = "retained-0.9";
        test = "inspect-retained-0.9";
      };
      invalidProjectionFails = true;
      invalidArtifactFails = true;
      invalidCommandFails = true;
      invalidNamespaceFails = true;
      invalidNamespaceShapeFails = true;
      invalidResultFails = true;
      variantShapeFails = true;
      staleHistoryFails = true;
      invalidProfileFails = true;
      invalidCiProfileFails = true;
      invalidNativeInterfaceFails = true;
    };
  };
}
