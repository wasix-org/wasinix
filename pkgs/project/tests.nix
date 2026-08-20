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
  loaded =
    projectLib.loadPackageOverlay {
      inherit contextFor;
      dir = ./tests/units;
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

  projectApi = import ./default.nix {
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
    };
    crossSystemFor = profile: _spec: {wasinixProfile = profile;};
  };
  fakeImportNixpkgs = args: let
    base = {
      inherited = mkPackage {name = "inherited";};
      profile = args.crossSystem.wasinixProfile or "native";
    };
  in
    lib.fix (final: builtins.foldl' (previous: overlay: previous // overlay final previous) base args.overlays);
  consumerExtension = {
    id = "consumer";
    overlays.wasix = final: previous: {
      core = projectLib.extendPackage previous.core {
        passthru.wasinix.overrides = "wasinix";
      };
      consumer = mkPackage {
        name = "consumer-${final.profile}";
      };
      "dot.name" = mkPackage {name = "dot-name";};
      helper = "not-a-package";
      plumbing = mkPackage {
        name = "plumbing";
        passthru.wasinix.catalog = false;
      };
    };
  };
  unitExtension = {
    id = "unit-consumer";
    overlays = projectApi.loadPackageOverlays {
      wasix = ./tests/project-units;
    };
  };
  project = projectApi.mkProject {
    system = "test-system";
    importNixpkgs = fakeImportNixpkgs;
    extensions = [consumerExtension unitExtension];
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
in {
  packageUnits = {
    expr = {
      names = lib.attrNames loaded;
      existingInputs = map (package: package.name) loaded.existing.buildInputs;
      existingPolicy = loaded.existing.passthru.wasinix.test;
    };
    expected = {
      names = ["existing" "family-a" "family-b" "new"];
      existingInputs = ["dependency"];
      existingPolicy = true;
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
      ciSources = project.ci.sources;
      ciJobNames = lib.attrNames project.ci.jobs;
      catalogJobNames = lib.attrNames project.ci.catalog.jobs;
      unknownCiSourceFails = !(force unknownCiSource).success;
      duplicateExtensionFails = !(force duplicateExtension).success;
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
      ciSources = ["consumer"];
      ciJobNames = [
        "packages.wasix.alternate.consumer"
        "packages.wasix.alternate.core"
        ''packages.wasix.alternate["dot.name"]''
        "packages.wasix.default.consumer"
        "packages.wasix.default.core"
        ''packages.wasix.default["dot.name"]''
      ];
      catalogJobNames = [
        "packages.wasix.alternate.consumer"
        "packages.wasix.alternate.core"
        ''packages.wasix.alternate["dot.name"]''
        "packages.wasix.default.consumer"
        "packages.wasix.default.core"
        ''packages.wasix.default["dot.name"]''
      ];
      unknownCiSourceFails = true;
      duplicateExtensionFails = true;
    };
  };
}
