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
    rebasePackage = version: _spec: package:
      package.overrideAttrs (_: {
        inherit version;
        name = "${package.name}-${version}";
      });
  };
  projectApi = import ./default.nix (projectApiArgs
    // {
      checkRules.probe = {
        entry,
        packages,
        ...
      }:
        lib.optionalAttrs (entry.policy.checks.probe or false) {
          probe = mkPackage {name = "probe-${entry.package.name}-${packages.sameProfile.core.versions."0.9".version}";};
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
        };
        consumer = mkPackage {
          name = "consumer-${final.profile}";
          passthru.wasinix.checks.probe = true;
        };
        "dot.name" = mkPackage {name = "dot-name";};
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
        overlays.wasix = final: _previous:
          lib.optionalAttrs (final.profile == "default") {
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
  duplicateCheckProject = (import ./default.nix (projectApiArgs
    // {
      checkRules = {
        first = {entry, ...}: lib.optionalAttrs (entry.policy.checks.probe or false) {same = mkPackage {};};
        second = {entry, ...}: lib.optionalAttrs (entry.policy.checks.probe or false) {same = mkPackage {};};
      };
    })).mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [consumerExtension];
  };
  invalidCheckProject = (import ./default.nix (projectApiArgs
    // {
      checkRules.invalid = {entry, ...}: lib.optionalAttrs (entry.policy.checks.probe or false) {invalid = "not a derivation";};
    })).mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [consumerExtension];
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
      defaultNames = lib.attrNames project.packages.wasix.default;
      coreSource = project.packages.wasix.default.core.passthru.wasinix.source;
      coreLineage = project.packages.wasix.default.core.passthru.wasinix.lineage;
      preferredProfile = project.packages.preferred.core.name;
      consumerName = project.packages.wasix.alternate.consumer.name;
      inheritedDependencyName = project.packages.wasix.default.uses-inherited.name;
      pythonNames = lib.attrNames project.packages.python.py;
      pythonSource = project.packages.python.py.uses-python.passthru.wasinix.source;
      pythonContextName = project.packages.python.py.contextProof.name;
      wasixHistoryVersion = project.packages.wasix.default.core.versions."0.9".version;
      preferredHistoryVersion = project.packages.preferred.core.versions."0.9".version;
      pythonHistoryVersion = project.packages.python.py.inheritedPython.versions."0.8".version;
      historyDependencyVersion = project.packages.python.py.inheritedPython.versions."0.8".passthru.wasinix.historyDependency;
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
      duplicateCheckFails = !(force duplicateCheckProject.tests).success;
      invalidCheckFails = !(force invalidCheckProject.tests).success;
      variantShapeFails = !(force variantShapeProject).success;
      staleHistoryFails = !(force staleHistoryProject).success;
    };
    expected = {
      schemaVersion = 1;
      nativeNames = ["core"];
      defaultNames = ["consumer" "core" "dot.name"];
      coreSource = "consumer";
      coreLineage = ["wasinix" "consumer"];
      preferredProfile = "core";
      consumerName = "consumer-alternate";
      inheritedDependencyName = "uses-inherited";
      pythonNames = ["contextProof" "corePython" "inheritedPython" "uses-python"];
      pythonSource = "consumer";
      pythonContextName = "top-owned-false";
      wasixHistoryVersion = "0.9";
      preferredHistoryVersion = "0.9";
      pythonHistoryVersion = "0.8";
      historyDependencyVersion = "0.9";
      historyTags = ["history-tests"];
      historyTestTags = ["history-tests"];
      ciSources = ["consumer"];
      ciJobNames = [
        "packages.python.py.inheritedPython"
        ''packages.python.py.inheritedPython.versions["0.8"]''
        ''packages.python.py["uses-python"]''
        "packages.wasix.alternate.consumer"
        "packages.wasix.alternate.core"
        ''packages.wasix.alternate.core.versions["0.9"]''
        ''packages.wasix.alternate["dot.name"]''
        "packages.wasix.default.consumer"
        "packages.wasix.default.core"
        ''packages.wasix.default.core.versions["0.9"]''
        ''packages.wasix.default["dot.name"]''
        "tests.packages.wasix.alternate.consumer.probe"
        "tests.packages.wasix.alternate.core.probe"
        ''tests.packages.wasix.alternate.core.versions["0.9"].probe''
        "tests.packages.wasix.default.consumer.probe"
        "tests.packages.wasix.default.core.probe"
        ''tests.packages.wasix.default.core.versions["0.9"].probe''
      ];
      catalogJobNames = [
        "packages.python.py.inheritedPython"
        ''packages.python.py.inheritedPython.versions["0.8"]''
        ''packages.python.py["uses-python"]''
        "packages.wasix.alternate.consumer"
        "packages.wasix.alternate.core"
        ''packages.wasix.alternate.core.versions["0.9"]''
        ''packages.wasix.alternate["dot.name"]''
        "packages.wasix.default.consumer"
        "packages.wasix.default.core"
        ''packages.wasix.default.core.versions["0.9"]''
        ''packages.wasix.default["dot.name"]''
        "tests.packages.wasix.alternate.consumer.probe"
        "tests.packages.wasix.alternate.core.probe"
        ''tests.packages.wasix.alternate.core.versions["0.9"].probe''
        "tests.packages.wasix.default.consumer.probe"
        "tests.packages.wasix.default.core.probe"
        ''tests.packages.wasix.default.core.versions["0.9"].probe''
      ];
      testNames = [
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
      duplicateCheckFails = true;
      invalidCheckFails = true;
      variantShapeFails = true;
      staleHistoryFails = true;
    };
  };
}
