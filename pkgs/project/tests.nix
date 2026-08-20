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
  prev = {existing = previous;};
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
    };
    builtInExtension = {
      id = "wasinix";
      overlays.shared = _final: _previous: {
        core = mkPackage {
          name = "core";
          passthru.wasix.preferredProfile = "alternate";
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
    nativePackageInterfacesFor = project': {
      core.profiles.default.package = project'.packages.wasix.default.core;
    };
    rebasePackage = version: _spec: package:
      package.overrideAttrs (_: {
        inherit version;
        name = "${package.name}-${version}";
      });
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
  project = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [consumerExtension unitExtension pythonContextExtension];
    ci.sources = ["consumer"];
  };
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
      nativePackageInterfacesFor = _project: {
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
in {
  packageUnits = {
    expr = {
      names = lib.attrNames loaded;
      existingInputs = map (package: package.name) loaded.existing.buildInputs;
      existingPolicy = loaded.existing.passthru.wasinix.test;
      replayNames = lib.attrNames loadedRaw.${projectLib.unitOverlaysAttr};
      bareUnitFails = !(force bareUnit).success;
    };
    expected = {
      names = ["existing" "family-a" "family-b" "new"];
      existingInputs = ["dependency"];
      existingPolicy = true;
      replayNames = ["existing" "family-a" "family-b" "new"];
      bareUnitFails = true;
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
    };
    expected = {
      coreSource = "wasinix";
      delistedSource = "wasinix";
      extensionSource = "my-project";
      extensionLineage = ["wasinix" "my-project"];
      missingDeclarationFails = true;
      orphanDeclarationFails = true;
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
      pythonNames = lib.attrNames project.packages.python.py;
      pythonSource = project.packages.python.py.uses-python.passthru.wasinix.source;
      pythonContextName = project.packages.python.py.contextProof.name;
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
      pythonNames = ["contextProof" "corePython" "inheritedPython" "uses-python"];
      pythonSource = "consumer";
      pythonContextName = "top-owned-";
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
