{
  lib,
  profiles,
  builtInExtension ? null,
  projectionRules ? {},
  crossSystemFor,
  configFor ? _args: {},
  setOverlaysFor ? _args: [],
  nativePackageInterfacesFor ? _args: {},
  harnessesFor ? _args: {},
  runnersFor ? _args: {},
  projectionContextFor ? _args: {},
  validateProject ? _args: true,
  pythonSetsFor ? _args: {},
  packageTransformFor ? _args: _name: package: package,
  extendPythonSet ? packageSet: overlay: packageSet.overrideScope overlay,
  repairPythonPackage ? package:
    if package ? pythonModule
    then
      package.overrideAttrs (old: {
        passthru =
          (old.passthru or {})
          // {
            requiredPythonModules = package.pythonModule.pkgs.requiredPythonModules (old.propagatedBuildInputs or []);
          };
      })
    else package,
}: let
  projectLib = import ./lib.nix {inherit lib;};
  schema = builtins.fromJSON (builtins.readFile ../../schema/project.json);
  extendPythonPackage = projectLib.extendPythonPackage repairPythonPackage;
  defaultExtensions = lib.optional (builtInExtension != null) builtInExtension;
  defaultProjectionRules = projectionRules;
  extensionError = extension: message:
    throw "Wasinix extension '${extension.id}' ${message}";

  declaredOverlayFor = {
    contextFor,
    declared,
    extension,
    label,
    applyFunction ? function: function,
    extendPackageFor ? null,
  }:
    if builtins.isFunction declared
    then applyFunction declared
    else if lib.isAttrs declared && declared.__wasinixPackageDirectory or false
    then
      projectLib.loadPackageOverlay ({
          inherit contextFor;
          dir = declared.directory;
          expose = declared.expose or [];
        }
        // lib.optionalAttrs (extendPackageFor != null) {inherit extendPackageFor;})
    else extensionError extension "${label} is not an overlay";

  registerExtensionOverlay = {
    declared,
    extension,
    overlay,
  }:
    projectLib.registerOverlay {
      inherit overlay;
      definition =
        if lib.isAttrs declared
        then declared.definition or null
        else null;
      source = extension.id;
    };

  validateExtension = extension: let
    id = extension.id or null;
    invalidLanes = lib.subtractLists ["shared" "native" "wasix" "python"] (lib.attrNames (extension.overlays or {}));
    invalidHistory = lib.subtractLists ["wasix" "python"] (lib.attrNames (extension.history or {}));
  in
    lib.throwIf (
      !builtins.isString id
      || builtins.match "[a-z0-9][a-z0-9._-]*" id == null
    )
    "Wasinix extension IDs must use lowercase letters, numbers, '.', '_', or '-'"
    (lib.throwIf (invalidLanes != [])
      "Wasinix extension '${id}' has unknown overlay lane(s): ${lib.concatStringsSep ", " invalidLanes}"
      (lib.throwIf (invalidHistory != [])
        "Wasinix extension '${id}' has unknown history lane(s): ${lib.concatStringsSep ", " invalidHistory}"
        extension));

  ensureUniqueExtensions = extensions: let
    grouped = lib.groupBy (extension: extension.id) extensions;
    duplicates = lib.attrNames (lib.filterAttrs (_: values: lib.length values > 1) grouped);
  in
    lib.throwIf (duplicates != [])
    "duplicate Wasinix extension ID(s): ${lib.concatStringsSep ", " duplicates}"
    extensions;

  laneOverlay = {
    contextFor,
    declared,
    enabled ? _previous: true,
    extension,
    label,
    applyFunction ? function: function,
    extendPackageFor ? null,
    preparePackage ? package: package,
    scope,
    variant,
  }: let
    rawOverlay = declaredOverlayFor {
      inherit contextFor declared extension;
      inherit label applyFunction extendPackageFor;
    };
    overlay = final: previous:
      lib.optionalAttrs (enabled previous)
      (lib.mapAttrs (name: value:
        if lib.isDerivation value
        then
          packageTransformFor {
            inherit scope variant;
            packageSet = previous;
          }
          name
          (preparePackage value)
        else value)
      (rawOverlay final previous));
  in
    registerExtensionOverlay {inherit declared extension overlay;};

  captureExtensionContext = extension: final: prev: {
    ${projectLib.extensionContextsAttr} =
      (prev.${projectLib.extensionContextsAttr} or {})
      // {${extension.id} = {inherit final prev;};};
  };

  packageEntry = {
    address,
    name,
    package,
    preferred ? false,
    projectionPath,
    scope,
    variant,
  }: let
    metadata = projectLib.packageMetadata package;
    policy = removeAttrs metadata projectLib.machineMetadata;
  in {
    kind = "package";
    build = package;
    inherit address name package preferred projectionPath scope variant;
    inherit (metadata) definition source lineage instance;
    subjects = [];
    packageSubjects = [address];
    inherit policy;
  };

  serializableEntry = entry:
    {
      inherit (entry) kind address name source lineage scope variant instance subjects packageSubjects;
      policy = {
        aliases = aliasAddressesFor entry;
        shipped = entry.policy.shipped or false;
        ci = entry.policy.ci or {};
        publication = entry.policy.publication or {};
        retention = entry.policy.retention or null;
      };
    }
    // lib.optionalAttrs (entry ? artifactKind) {inherit (entry) artifactKind;}
    // lib.optionalAttrs (lib.length (entry.packageSubjects or []) == 1) {
      packageSubject = builtins.head entry.packageSubjects;
    }
    // lib.optionalAttrs (entry ? subject) {inherit (entry) subject;}
    // lib.optionalAttrs (entry ? testName) {inherit (entry) testName;}
    // lib.optionalAttrs (entry.kind == "package" && entry.scope == "wasix") {
      spotTarget = "${entry.variant.profile}.${entry.name}";
    };

  aliasAddressesFor = entry: let
    aliases = entry.policy.aliases or [];
    projectionPathFor = alias: [alias] ++ builtins.tail entry.projectionPath;
    addressFor = alias:
      if entry.kind == "package"
      then
        projectLib.address "packages" (
          (
            if entry.scope == "native"
            then ["native"]
            else if entry.scope == "wasix"
            then ["wasix" entry.variant.profile]
            else ["python" entry.variant.interpreter]
          )
          ++ projectionPathFor alias
        )
      else projectLib.address "artifacts" ([entry.artifactKind] ++ projectionPathFor alias);
  in
    if builtins.elem entry.kind ["package" "artifact"]
    then map addressFor (lib.unique (lib.filter (alias: alias != entry.name) aliases))
    else [];

  projectionsFor = {
    context,
    entry,
    namespaces ? ["artifacts" "commands" "tests"],
    rules,
  }: let
    knownNamespaces = ["artifacts" "commands" "tests" "versions"];
    resultFor = ruleName: rule: let
      declaredNamespaces =
        if builtins.isFunction rule
        then ["artifacts" "commands" "tests"]
        else rule.namespaces or [];
      function =
        if builtins.isFunction rule
        then rule
        else rule.entry or null;
      unknownDeclared = lib.subtractLists knownNamespaces declaredNamespaces;
      applies = lib.intersectLists namespaces declaredNamespaces != [];
      result =
        if applies && builtins.isFunction function
        then projectLib.callWith (context // {inherit entry;}) function
        else {};
      unknown = lib.subtractLists declaredNamespaces (lib.attrNames result);
    in
      if !builtins.isFunction function
      then {}
      else
        lib.throwIf (declaredNamespaces == [])
        "projection rule '${ruleName}' must declare at least one namespace"
        (lib.throwIf (unknownDeclared != [])
          "projection rule '${ruleName}' declares unknown namespace(s): ${lib.concatStringsSep ", " unknownDeclared}"
          (lib.throwIf (!lib.isAttrs result)
            "projection rule '${ruleName}' must return an attribute set"
            (lib.throwIf (unknown != [])
              "projection rule '${ruleName}' returned undeclared namespace(s): ${lib.concatStringsSep ", " unknown}"
              result)));
    results = lib.mapAttrs resultFor rules;
    validCommand = name: command:
      lib.isAttrs command
      && builtins.isString (command.name or null)
      && command.name == name
      && lib.isDerivation (command.artifact or null)
      && builtins.isString (command.entrypoint or null);
    validArtifact = artifact:
      lib.isDerivation artifact
      || (
        lib.isAttrs artifact
        && lib.isDerivation (artifact.artifact or null)
        && lib.isList (artifact.projectionPath or null)
        && lib.all builtins.isString artifact.projectionPath
      );
    invalidFor = namespace: values:
      if namespace == "artifacts"
      then lib.filterAttrs (_: artifact: !validArtifact artifact) values
      else if namespace == "commands"
      then lib.filterAttrs (name: command: !validCommand name command) values
      else lib.filterAttrs (_: value: !lib.isDerivation value) values;
    mergeNamespace = namespace: state: ruleName: result: let
      values = result.${namespace} or {};
      invalid = invalidFor namespace values;
      duplicates = lib.intersectLists (lib.attrNames state) (lib.attrNames values);
      singular =
        if namespace == "artifacts"
        then "artifact"
        else if namespace == "commands"
        then "command"
        else if namespace == "tests"
        then "test"
        else "package version";
    in
      lib.throwIf (!lib.isAttrs values)
      "projection rule '${ruleName}' returned non-attribute namespace '${namespace}'"
      (lib.throwIf (invalid != {})
        "projection rule '${ruleName}' returned invalid ${singular}(s): ${lib.concatStringsSep ", " (lib.attrNames invalid)}"
        (lib.throwIf (duplicates != [])
          "projection rule '${ruleName}' returned duplicate output(s) for ${entry.address}: ${lib.concatStringsSep ", " (map (name: "${namespace}.${name}") duplicates)}"
          (state // values)));
    namespaceFor = namespace:
      lib.foldlAttrs (mergeNamespace namespace) {} results;
  in
    lib.genAttrs namespaces namespaceFor;

  projectProjectionResults = {
    context,
    rules,
  }: let
    knownNamespaces = ["artifacts"];
    resultFor = ruleName: rule: let
      declaredNamespaces =
        if builtins.isFunction rule
        then []
        else rule.namespaces or [];
      function =
        if builtins.isFunction rule
        then null
        else rule.project or null;
      result =
        if builtins.isFunction function
        then projectLib.callWith context function
        else {};
      returnedNamespaces = lib.attrNames result;
      unknown = lib.subtractLists declaredNamespaces returnedNamespaces;
      unsupported = lib.subtractLists knownNamespaces returnedNamespaces;
    in
      if !builtins.isFunction function
      then {}
      else
        lib.throwIf (declaredNamespaces == [])
        "project projection rule '${ruleName}' must declare at least one namespace"
        (lib.throwIf (!lib.isAttrs result)
          "project projection rule '${ruleName}' must return an attribute set"
          (lib.throwIf (unknown != [])
            "project projection rule '${ruleName}' returned undeclared namespace(s): ${lib.concatStringsSep ", " unknown}"
            (lib.throwIf (unsupported != [])
              "project projection rule '${ruleName}' returned unsupported namespace(s): ${lib.concatStringsSep ", " unsupported}"
              result)));
  in
    lib.mapAttrs resultFor rules;

  validateVariantShapes = label: extensionIds: packageSets: let
    variants = lib.attrNames packageSets;
    namesFor = source: variant:
      lib.attrNames (lib.filterAttrs (_: owner: owner == source)
        (packageSets.${variant}.${projectLib.registryAttr} or {}));
    mismatches = lib.concatMap (source: let
      expected = namesFor source (builtins.head variants);
    in
      lib.concatMap (variant:
        lib.optional (namesFor source variant != expected)
        "${source}.${variant}")
      (builtins.tail variants))
    extensionIds;
  in
    lib.throwIf (variants != [] && mismatches != [])
    "${label} package-unit attributes vary by variant: ${lib.concatStringsSep ", " mismatches}"
    true;
in rec {
  inherit (projectLib) extendPackage loadPackageOverlays;

  mkProject = args @ {
    extensions ? [],
    projectionRules ? {},
    ci ? {},
    ...
  }: let
    duplicates = lib.intersectLists (lib.attrNames defaultProjectionRules) (lib.attrNames projectionRules);
  in
    lib.throwIf (duplicates != [])
    "projection rule(s) replace project defaults: ${lib.concatStringsSep ", " duplicates}"
    (mkEmptyProject (args
      // {
        extensions = defaultExtensions ++ extensions;
        projectionRules = defaultProjectionRules // projectionRules;
        ci =
          ci
          // {
            sources = ci.sources or (map (extension: extension.id) extensions);
          };
      }));

  mkEmptyProject = {
    system,
    importNixpkgs,
    extensions ? [],
    projectionRules ? {},
    projectTests ? {},
    ci ? {},
  }: let
    allExtensions = ensureUniqueExtensions (map validateExtension extensions);
    extensionIds = map (extension: extension.id) allExtensions;
    requestedCiSources = ci.sources or (map (extension: extension.id) extensions);
    unknownCiSources = lib.subtractLists extensionIds requestedCiSources;
    invalidProjectionRules = lib.attrNames (lib.filterAttrs (_: rule:
      !builtins.isFunction rule
      && (
        !lib.isAttrs rule
        || (!(builtins.isFunction (rule.entry or null)) && !(builtins.isFunction (rule.project or null)))
        || (rule ? entry && !(builtins.isFunction rule.entry))
        || (rule ? project && !(builtins.isFunction rule.project))
      ))
    projectionRules);
    invalidProjectTests = lib.attrNames (lib.filterAttrs (_: test:
      !lib.isAttrs test
      || !builtins.isString (test.source or null)
      || !builtins.isFunction (test.check or null))
    projectTests);
    unknownProjectTestSources = lib.subtractLists extensionIds (lib.unique (map (test: test.source) (lib.attrValues projectTests)));

    overlaysFor = contextFor: scope: variant: lanes:
      lib.concatMap (
        extension:
          [
            (captureExtensionContext extension)
          ]
          ++ map (lane: let
            declared = (extension.overlays or {}).${lane} or (_final: _prev: {});
          in
            laneOverlay {
              inherit contextFor declared extension scope variant;
              enabled = previous: lane != "wasix" || (previous.stdenv.hostPlatform.isWasix or false);
              label = "overlay lane '${lane}'";
            })
          lanes
      )
      allExtensions;

    project = let
      profileNames = lib.attrNames profiles.profiles;
      profileSets = {
        table = profiles.profiles;
        all = profileNames;
        pic = lib.filter (name: profiles.profiles.${name}.wasmPic or false) profileNames;
        withoutPic = lib.filter (name: !(profiles.profiles.${name}.wasmPic or false)) profileNames;
        withEh = lib.filter (name: (profiles.profiles.${name}.wasmExceptions or "no") != "no") profileNames;
      };

      supportedProfilesFor = package: let
        declared = ((package.passthru or {}).wasix or {}).supportedProfiles or profileNames;
        unknown = lib.subtractLists profileNames declared;
      in
        lib.throwIf (declared == [])
        "${package.pname or package.name}: supportedProfiles must not be empty"
        (lib.throwIf (unknown != [])
          "${package.pname or package.name}: supportedProfiles contains unknown profile(s): ${lib.concatStringsSep ", " unknown}"
          declared);

      preferredProfileFor = package: let
        metadata = (package.passthru or {}).wasix or {};
        supported = supportedProfilesFor package;
        preferred =
          metadata.preferredProfile
          or (
            if builtins.elem profiles.defaultProfileName supported
            then profiles.defaultProfileName
            else builtins.head supported
          );
      in
        lib.throwIf (!(builtins.elem preferred supported))
        "${package.pname or package.name}: preferred profile '${preferred}' is unsupported"
        preferred;

      ciProfilesFor = package: let
        compatibility = (package.passthru or {}).wasix or {};
        policy = projectLib.packageMetadata package;
        ci = policy.ci or {};
        supported = supportedProfilesFor package;
        selected =
          ci.profiles
          or (
            if compatibility ? preferredProfile || (policy.shipped or false)
            then [(preferredProfileFor package)]
            else supported
          );
        unsupported = lib.subtractLists supported selected;
      in
        lib.throwIf (unsupported != [])
        "${package.pname or package.name}: CI selects unsupported profile(s): ${lib.concatStringsSep ", " unsupported}"
        selected;

      ciAvailable = package: let
        attempted = builtins.tryEval (!(package.meta.broken or false) && (package.meta.available or true));
      in
        !attempted.success || attempted.value;

      packageSetView = _scope: _variant: finalSet:
        projectLib.registeredPackages finalSet;

      projectedPackageFor = scope: variant: _finalSet: name: rawPackage: let
        package = rawPackage;
        address =
          if scope == "native"
          then projectLib.address "packages" ["native" name]
          else if scope == "wasix"
          then projectLib.address "packages" ["wasix" variant.profile name]
          else projectLib.address "packages" ["python" variant.interpreter name];
        cataloged = (projectLib.packageMetadata package).catalog or true;
        supported = scope != "wasix" || builtins.elem variant.profile (supportedProfilesFor package);
      in
        if cataloged && supported
        then
          (projectEntry (packageEntry {
            inherit address name package scope variant;
            preferred = scope == "wasix" && preferredProfileFor package == variant.profile;
            projectionPath = [name];
          })).value
        else package;

      projectedPackageSet = scope: variant: finalSet:
        lib.mapAttrs (name: package:
          if lib.isDerivation package && ((projectLib.packageMetadata package).source or null) != null
          then projectedPackageFor scope variant finalSet name package
          else package)
        finalSet;

      sharedProjectionContext = {
        inherit lib pythonVariants;
        packageSets = packageSetsView;
        commands = commandsView;
        artifacts = artifactsView;
        tests = lib.mapAttrs (_: entry: entry.check) testEntries;
        catalog = {inherit entries;};
        harnesses = harnessesView;
        runners = runnersView;
        probes = probesView;
        inherit profileSets;
        inherit (profiles) profileOf;
        profileTraitsOf = platform: profiles.sysrootEncodings.${profiles.profileOf platform};
        inherit (projectLib) buildHostPypaTools dropFlagsByPrefix dropInputsByName dropInputsByNameInfix dropPatchesByNameInfix dropSphinxDocs extendPackage linkInputs mergeScript packageForEntry replaceInputsByName wasmRename;
      };

      contextFor = scope: variant: enclosingPkgs: {final, ...}:
        sharedProjectionContext
        // {
          packages = {
            native = nativeForContext;
            inherit wasix preferred;
            python = python // lib.optionalAttrs (preferredPythonInterpreter != null) {preferred = python.${preferredPythonInterpreter};};
            sameProfile = projectedPackageSet scope variant final;
          };
          pkgs =
            if enclosingPkgs != null
            then enclosingPkgs
            else if scope == "wasix"
            then nativeRaw
            else final;
        };

      nativeRaw = importNixpkgs {
        localSystem = {inherit system;};
        config = configFor {
          inherit project;
          nativeRaw = null;
          scope = "native";
          variant = {};
        };
        overlays =
          setOverlaysFor {
            inherit project;
            nativeRaw = null;
            scope = "native";
            variant = {};
            packageRecipesOverlay = args:
              projectLib.loadRecipeOverlay ({
                  contextFor = contextFor "native" {} null;
                }
                // args);
          }
          ++ overlaysFor (contextFor "native" {} null) "native" {} ["shared" "native"];
      };

      wasixRaw =
        lib.mapAttrs (
          profile: spec:
            importNixpkgs {
              localSystem = {inherit system;};
              crossSystem = crossSystemFor profile spec;
              config = configFor {
                inherit project nativeRaw;
                scope = "wasix";
                variant = {inherit profile;};
              };
              overlays =
                setOverlaysFor {
                  inherit project nativeRaw;
                  scope = "wasix";
                  variant = {inherit profile;};
                  packageRecipesOverlay = args:
                    projectLib.loadRecipeOverlay ({
                        contextFor = contextFor "wasix" {inherit profile;} null;
                      }
                      // args);
                }
                ++ overlaysFor (contextFor "wasix" {inherit profile;} null) "wasix" {inherit profile;} ["shared" "wasix"];
            }
        )
        profiles.profiles;

      pythonSpecs = pythonSetsFor {inherit project nativeRaw wasixRaw;};
      preferredPythonInterpreters = lib.attrNames (lib.filterAttrs (_: spec: spec.preferred or false) pythonSpecs);
      preferredPythonInterpreter =
        if preferredPythonInterpreters == []
        then null
        else builtins.head preferredPythonInterpreters;
      pythonPreferenceValid =
        lib.throwIf (lib.length preferredPythonInterpreters > 1)
        "multiple preferred Python interpreters: ${lib.concatStringsSep ", " preferredPythonInterpreters}"
        true;
      pythonRaw = lib.mapAttrs (interpreter: spec: (lib.foldl' (
          packageSet: extension:
            if (extension.overlays or {}) ? python
            then let
              enclosingContext = spec.pkgs.${projectLib.extensionContextsAttr}.${extension.id};
            in
              extendPythonSet packageSet (laneOverlay {
                contextFor = contextFor "python" {inherit interpreter;} spec.pkgs;
                declared = extension.overlays.python;
                enabled = previous: previous.python.stdenv.hostPlatform.isWasix or false;
                inherit extension;
                label = "Python lane";
                applyFunction = function: function enclosingContext.final enclosingContext.prev;
                extendPackageFor = extendPythonPackage;
                preparePackage = repairPythonPackage;
                scope = "python";
                variant = {inherit interpreter;};
              })
            else packageSet
        )
        spec.packageSet
        allExtensions))
      pythonSpecs;

      wasixShapesValid = validateVariantShapes "WASIX" extensionIds wasixRaw;
      pythonShapesValid = validateVariantShapes "Python" extensionIds pythonRaw;

      nativePackageInterfaces = nativePackageInterfacesFor {
        inherit project nativeRaw wasixRaw pythonRaw;
      };
      nativeForContext = lib.genAttrs (projectLib.registeredNames nativeRaw) (name:
        projectedPackageFor "native" {} nativeRaw name nativeRaw.${name}
        // (nativePackageInterfaces.${name} or {}));
      unknownInterfacePackages = lib.subtractLists (projectLib.registeredNames nativeRaw) (lib.attrNames nativePackageInterfaces);
      nativeInterfacesValid =
        lib.throwIf (unknownInterfacePackages != [])
        "native package interfaces target unknown package(s): ${lib.concatStringsSep ", " unknownInterfacePackages}"
        true;
      baseNative = lib.mapAttrs (name: package:
        package // (nativePackageInterfaces.${name} or {}))
      (packageSetView "native" {} nativeRaw);
      baseWasix = lib.mapAttrs (profile: packageSet:
        lib.filterAttrs (_: package: builtins.elem profile (supportedProfilesFor package))
        (packageSetView "wasix" {inherit profile;} packageSet))
      wasixRaw;
      basePython = lib.mapAttrs (interpreter: packageSet:
        packageSetView "python" {inherit interpreter;} packageSet)
      pythonRaw;
      projectValid = validateProject {
        extensions = allExtensions;
        packageSets = {
          native = nativeRaw;
          wasix = wasixRaw;
          python = pythonRaw;
        };
      };
      allWasixNames = lib.unique (lib.concatMap projectLib.registeredNames (lib.attrValues wasixRaw));
      preferredProfileNameFor = name: let
        defaultProfile = profiles.defaultProfileName or null;
        packageAtDefault = wasixRaw.${defaultProfile}.${name};
        declaredProfile = preferredProfileFor packageAtDefault;
      in
        lib.throwIf (defaultProfile == null)
        "the WASIX profile inventory does not define defaultProfileName"
        (lib.throwIf (!(builtins.elem declaredProfile (supportedProfilesFor wasixRaw.${declaredProfile}.${name})))
          "${name}: preferred WASIX profile '${declaredProfile}' is unavailable"
          declaredProfile);
      callbackArgs = {
        inherit project nativeRaw wasixRaw pythonRaw;
      };
      harnessesView = harnessesFor callbackArgs;
      runnersView = runnersFor callbackArgs;
      probesView.ifd = nativeRaw.writeText "wasinix-ifd-probe" "ok";
      packageSetsView = {
        native = nativeRaw;
        wasix = wasixRaw;
        python = pythonRaw;
        preferred = lib.genAttrs allWasixNames (name: let
          profile = preferredProfileNameFor name;
        in
          wasixRaw.${profile}.${name});
      };
      pythonVariants = {
        all = lib.attrNames pythonSpecs;
        preferred = preferredPythonInterpreter;
        specs =
          lib.mapAttrs (_: spec: {
            inherit (spec) interpreterPackage;
          })
          pythonSpecs;
      };
      contextForEntry = entry: let
        selected =
          if entry.scope == "native"
          then {
            final = nativeRaw;
            enclosing = null;
          }
          else if entry.scope == "wasix"
          then {
            final = wasixRaw.${entry.variant.profile};
            enclosing = null;
          }
          else {
            final = pythonRaw.${entry.variant.interpreter};
            enclosing = pythonSpecs.${entry.variant.interpreter}.pkgs;
          };
      in
        contextFor entry.scope entry.variant selected.enclosing {inherit (selected) final;}
        // (projectionContextFor {
          extensions = allExtensions;
          finalSet = selected.final;
          inherit entry packageTransformFor repairPythonPackage;
        });

      nativeEntries = lib.mapAttrs' (name: package: let
        address = projectLib.address "packages" ["native" name];
      in
        lib.nameValuePair address (packageEntry {
          inherit address name package;
          projectionPath = [name];
          scope = "native";
          variant = {};
        }))
      baseNative;
      wasixEntries = lib.concatMapAttrs (profile: packages:
        lib.mapAttrs' (name: package: let
          address = projectLib.address "packages" ["wasix" profile name];
        in
          lib.nameValuePair address (packageEntry {
            inherit address name package;
            preferred = preferredProfileNameFor name == profile;
            projectionPath = [name];
            scope = "wasix";
            variant = {inherit profile;};
          }))
        packages)
      baseWasix;
      pythonEntries = lib.concatMapAttrs (interpreter: packages:
        lib.mapAttrs' (name: package: let
          address = projectLib.address "packages" ["python" interpreter name];
        in
          lib.nameValuePair address (packageEntry {
            inherit address name package;
            projectionPath = [name];
            scope = "python";
            variant = {inherit interpreter;};
          }))
        packages)
      basePython;
      currentPackageEntries = nativeEntries // wasixEntries // pythonEntries;
      projectTestEntries = lib.mapAttrs' (name: test: let
        address = projectLib.address "tests" ["project" name];
        check = test.check project;
      in
        lib.nameValuePair address {
          kind = "test";
          build = check;
          inherit address check name;
          testName = name;
          inherit (test) source;
          lineage = [test.source];
          scope = "native";
          variant = {};
          instance = {
            kind = "current";
            version = toString (test.version or "project");
          };
          subject = "project";
          subjects = [];
          packageSubjects = [];
          policy = {
            aliases = [];
            shipped = false;
            ci = test.ci or {};
            publication = {};
            retention = null;
          };
        })
      projectTests;
      inheritedPolicy = subject: drv: let
        own = removeAttrs (projectLib.packageMetadata drv) projectLib.machineMetadata;
        subjectCi = subject.policy.ci or {};
        ownCi = own.ci or {};
      in
        subject.policy
        // own
        // {
          ci =
            subjectCi
            // ownCi
            // {tags = lib.unique ((subjectCi.tags or []) ++ (ownCi.tags or []));};
        };
      mergeDisjoint = label: sets: let
        entries = lib.concatMap (lib.mapAttrsToList (name: value: {inherit name value;})) sets;
        grouped = lib.groupBy (entry: entry.name) entries;
        duplicates = lib.attrNames (lib.filterAttrs (_: values: lib.length values > 1) grouped);
      in
        lib.throwIf (duplicates != [])
        "duplicate ${label} address(es): ${lib.concatStringsSep ", " duplicates}"
        (builtins.listToAttrs entries);
      mergeProjectionCollections = collections: {
        packages = mergeDisjoint "package" (map (collection: collection.packages) collections);
        artifacts = mergeDisjoint "artifact" (map (collection: collection.artifacts) collections);
        commands = mergeDisjoint "command" (map (collection: collection.commands) collections);
        tests = mergeDisjoint "test" (map (collection: collection.tests) collections);
      };
      projectEntry = baseEntry: let
        projectionContext = contextForEntry baseEntry;
        versionOutputs = projectionsFor {
          context = projectionContext;
          entry = baseEntry;
          namespaces = ["versions"];
          rules = projectionRules;
        };
        outputs = projectionsFor {
          context = projectionContext;
          inherit entry;
          rules = projectionRules;
        };
        versionNodes =
          lib.throwIf (
            versionOutputs.versions
            != {}
            && (
              baseEntry.kind
              != "package"
              || baseEntry.instance.kind != "current"
            )
          )
          "projection of ${baseEntry.address} returned package versions for a non-current package"
          (lib.mapAttrs (version: package:
            projectEntry (packageEntry {
              address = "${baseEntry.address}.versions${projectLib.addressSegment version}";
              inherit package;
              inherit (baseEntry) name preferred scope variant;
              projectionPath = baseEntry.projectionPath ++ ["versions" version];
            }))
          versionOutputs.versions);
        artifactNodes = lib.mapAttrs (kind: declared: let
          artifact =
            if lib.isDerivation declared
            then declared
            else declared.artifact;
          projectionPath =
            if lib.isDerivation declared
            then baseEntry.projectionPath
            else declared.projectionPath;
        in
          projectEntry ({
              kind = "artifact";
              address = projectLib.address "artifacts" ([kind] ++ projectionPath);
              artifactKind = kind;
              build = artifact;
              inherit artifact projectionPath;
              inherit (baseEntry) name preferred definition source lineage scope variant instance;
              subject = baseEntry.address;
              subjects = [baseEntry.address];
              inherit (baseEntry) packageSubjects;
              policy = inheritedPolicy baseEntry artifact;
            }
            // lib.optionalAttrs (!lib.isDerivation declared && declared ? name) {inherit (declared) name;}))
        outputs.artifacts;
        relativeArtifacts = lib.mapAttrs (_: node: node.value) artifactNodes;
        relativeCommands = mergeDisjoint "relative command" (
          [outputs.commands]
          ++ map (node: node.entry.commands) (lib.attrValues artifactNodes)
        );
        versions = lib.optionalAttrs (versionNodes != {}) {
          versions = lib.mapAttrs (_: node: node.value) versionNodes;
        };
        relative = {
          artifacts = relativeArtifacts;
          commands = relativeCommands;
          inherit (outputs) tests;
        };
        value =
          (
            if baseEntry.kind == "package"
            then baseEntry.package
            else baseEntry.artifact
          )
          // versions
          // relative;
        entry =
          baseEntry
          // relative
          // (
            if baseEntry.kind == "package"
            then {package = value;}
            else {artifact = value;}
          );
        ownArtifacts = lib.mapAttrs' (_: node: lib.nameValuePair node.entry.address node.entry) artifactNodes;
        ownVersions = lib.mapAttrs' (_: node: lib.nameValuePair node.entry.address node.entry) versionNodes;
        ownCommands = lib.mapAttrs' (name: command: let
          commandVersion =
            if (command.version or "") != ""
            then command.version
            else if baseEntry.instance.kind == "history"
            then baseEntry.instance.version
            else null;
          projectionPath =
            (
              if command.global or true
              then [name]
              else [name "from" baseEntry.name]
            )
            ++ lib.optionals (commandVersion != null) ["versions" commandVersion];
          address = projectLib.address "commands" projectionPath;
        in
          lib.nameValuePair address {
            kind = "command";
            inherit address command projectionPath;
            inherit (baseEntry) definition source lineage scope variant instance;
            subject = baseEntry.address;
            subjects = [baseEntry.address];
            inherit (baseEntry) packageSubjects;
            inherit (baseEntry) policy;
          })
        outputs.commands;
        ownTests = lib.mapAttrs' (name: check: let
          address = "tests.${baseEntry.address}${projectLib.addressSegment name}";
        in
          lib.nameValuePair address {
            kind = "test";
            build = check;
            inherit address check;
            inherit (baseEntry) name;
            testName = name;
            inherit (baseEntry) definition source lineage scope variant instance;
            subject = baseEntry.address;
            subjects = [baseEntry.address];
            inherit (baseEntry) packageSubjects;
            policy = inheritedPolicy baseEntry check;
          })
        outputs.tests;
        descendants = mergeProjectionCollections (map (node: node.descendants) (lib.attrValues versionNodes ++ lib.attrValues artifactNodes));
      in {
        inherit entry value;
        descendants = mergeProjectionCollections [
          descendants
          {
            packages = ownVersions;
            artifacts = ownArtifacts;
            commands = ownCommands;
            tests = ownTests;
          }
        ];
      };
      flattenProjectArtifacts = ruleName: source: path: value:
        if lib.isDerivation value || (lib.isAttrs value && value ? artifact)
        then [
          {
            inherit path ruleName source;
            declared = value;
          }
        ]
        else if lib.isAttrs value
        then
          lib.concatLists (lib.mapAttrsToList (
              name: child:
                flattenProjectArtifacts ruleName source (path ++ [name]) child
            )
            value)
        else throw "project projection rule '${ruleName}' returned an invalid artifact at ${projectLib.address "artifacts" path}";
      projectProjectionContext =
        sharedProjectionContext
        // {
          packages = packageViews;
          pkgs = nativeRaw;
        };
      projectProjectionOutputs = projectProjectionResults {
        context = projectProjectionContext;
        rules = projectionRules;
      };
      projectArtifactDeclarations = lib.concatLists (lib.mapAttrsToList (ruleName: result: let
        rule = projectionRules.${ruleName};
        source = rule.source or null;
      in
        flattenProjectArtifacts ruleName source [] (result.artifacts or {}))
      projectProjectionOutputs);
      projectArtifactGroups = lib.groupBy (declaration:
        projectLib.address "artifacts" declaration.path)
      projectArtifactDeclarations;
      duplicateProjectArtifacts = lib.attrNames (lib.filterAttrs (_: declarations: lib.length declarations > 1) projectArtifactGroups);
      aggregateArtifactBases = lib.mapAttrs (address: declarations: let
        declaration = builtins.head declarations;
        inherit (declaration) declared;
        artifact =
          if lib.isDerivation declared
          then declared
          else declared.artifact;
        source =
          if lib.isAttrs declared && declared ? source
          then declared.source
          else declaration.source;
        subjects =
          if lib.isAttrs declared
          then declared.subjects or []
          else [];
        metadata = removeAttrs (projectLib.packageMetadata artifact) projectLib.machineMetadata;
        policy =
          {
            aliases = [];
            shipped = false;
            ci = {};
            publication = {};
            retention = null;
          }
          // metadata
          // (
            if lib.isAttrs declared
            then declared.policy or {}
            else {}
          );
        inherit (declaration) path;
        artifactKind = builtins.head path;
        projectionPath = builtins.tail path;
        name =
          if lib.isAttrs declared && declared ? name
          then declared.name
          else lib.last path;
        packageSubjects = lib.unique (lib.concatMap (subject:
          (entries.${subject} or {packageSubjects = [];}).packageSubjects)
        subjects);
      in
        lib.throwIf (path == [])
        "project projection rule '${declaration.ruleName}' returned an artifact without a path"
        (lib.throwIf (!builtins.isString source || !(builtins.elem source extensionIds))
          "project projection rule '${declaration.ruleName}' must declare a registered source"
          {
            kind = "artifact";
            inherit address artifact artifactKind name packageSubjects policy projectionPath source subjects;
            build = artifact;
            definition = null;
            lineage = [source];
            scope =
              if lib.isAttrs declared
              then declared.scope or "native"
              else "native";
            variant =
              if lib.isAttrs declared
              then declared.variant or {}
              else {};
            instance =
              if lib.isAttrs declared
              then
                declared.instance or {
                  kind = "current";
                  version = "project";
                }
              else {
                kind = "current";
                version = "project";
              };
            subject =
              if subjects == []
              then "project"
              else builtins.head subjects;
          }))
      projectArtifactGroups;
      aggregateArtifactNodes =
        lib.throwIf (duplicateProjectArtifacts != [])
        "duplicate project artifact address(es): ${lib.concatStringsSep ", " duplicateProjectArtifacts}"
        (lib.mapAttrs (_: projectEntry) aggregateArtifactBases);
      projectedPackageNodes = lib.mapAttrs (_: projectEntry) currentPackageEntries;
      packageProjected = mergeProjectionCollections (map (node: node.descendants) (lib.attrValues projectedPackageNodes));
      aggregateProjected = mergeProjectionCollections (map (node: node.descendants) (lib.attrValues aggregateArtifactNodes));
      projectedPackageEntries =
        lib.mapAttrs (_: node: node.entry) projectedPackageNodes
        // packageProjected.packages;
      artifactEntries = mergeDisjoint "artifact" [
        (lib.mapAttrs (_: node: node.entry) aggregateArtifactNodes)
        packageProjected.artifacts
        aggregateProjected.artifacts
      ];
      commandEntries = mergeDisjoint "command" [packageProjected.commands aggregateProjected.commands];
      testEntries = mergeDisjoint "test" [packageProjected.tests aggregateProjected.tests projectTestEntries];
      entries = mergeDisjoint "catalog" [projectedPackageEntries artifactEntries commandEntries testEntries];
      invalidSubjectEntries = lib.attrNames (lib.filterAttrs (_: entry:
        !builtins.isList entry.subjects || !lib.all builtins.isString entry.subjects)
      entries);
      unknownSubjects = lib.unique (lib.concatMap (entry:
        lib.subtractLists (lib.attrNames entries) entry.subjects)
      (lib.attrValues entries));
      subjectsValid =
        lib.throwIf (invalidSubjectEntries != [])
        "catalog entries have invalid subjects: ${lib.concatStringsSep ", " invalidSubjectEntries}"
        (lib.throwIf (unknownSubjects != [])
          "catalog entries name unknown subject(s): ${lib.concatStringsSep ", " unknownSubjects}"
          true);
      aliasClaims = lib.concatMap (entry:
        map (alias: {
          inherit alias;
          target = entry.address;
        })
        (aliasAddressesFor entry))
      (lib.attrValues entries);
      aliasTargets =
        lib.mapAttrs (_: claims: lib.unique (map (claim: claim.target) claims))
        (lib.groupBy (claim: claim.alias) aliasClaims);
      ambiguousAliases = lib.attrNames (lib.filterAttrs (_: targets: lib.length targets > 1) aliasTargets);
      shadowingAliases = lib.attrNames (lib.filterAttrs (alias: targets:
        builtins.hasAttr alias entries && !(builtins.elem alias targets))
      aliasTargets);
      aliasesValid =
        lib.throwIf (ambiguousAliases != [])
        "catalog aliases resolve to several entries: ${lib.concatStringsSep ", " ambiguousAliases}"
        (lib.throwIf (shadowingAliases != [])
          "catalog aliases shadow canonical entries: ${lib.concatStringsSep ", " shadowingAliases}"
          true);
      native = lib.mapAttrs (name: _:
        projectedPackageNodes.${projectLib.address "packages" ["native" name]}.value)
      baseNative;
      wasix = lib.mapAttrs (profile: packages:
        lib.mapAttrs (name: _:
          projectedPackageNodes.${projectLib.address "packages" ["wasix" profile name]}.value)
        packages)
      baseWasix;
      python = lib.mapAttrs (interpreter: packages:
        lib.mapAttrs (name: _:
          projectedPackageNodes.${projectLib.address "packages" ["python" interpreter name]}.value)
        packages)
      basePython;
      preferred = lib.genAttrs allWasixNames (name: let
        profile = preferredProfileNameFor name;
      in
        projectedPackageFor "wasix" {inherit profile;} wasixRaw.${profile} name wasixRaw.${profile}.${name});
      packageViews = {
        inherit native wasix preferred;
        python = python // lib.optionalAttrs (preferredPythonInterpreter != null) {preferred = python.${preferredPythonInterpreter};};
      };
      artifactsView = lib.foldl' lib.recursiveUpdate {} (map (entry:
        lib.setAttrByPath ([entry.artifactKind] ++ entry.projectionPath) entry.artifact)
      (lib.attrValues artifactEntries));
      commandsView = lib.foldl' lib.recursiveUpdate {} (map (entry:
        lib.setAttrByPath entry.projectionPath entry.command)
      (lib.attrValues (lib.filterAttrs (_: entry: entry.command.global or true) commandEntries)));
      ciPackageEntries = lib.filterAttrs (_: entry:
        builtins.elem entry.source requestedCiSources
        && ciAvailable entry.package
        && (
          entry.scope
          != "wasix"
          || builtins.elem entry.variant.profile (ciProfilesFor entry.package)
        ))
      projectedPackageEntries;
      ciPackageAddresses = lib.attrNames ciPackageEntries;
      ciArtifactEntries = lib.filterAttrs (_: entry:
        lib.intersectLists entry.packageSubjects ciPackageAddresses != [])
      artifactEntries;
      ciTestEntries = lib.filterAttrs (_: entry:
        if entry.packageSubjects != []
        then lib.intersectLists entry.packageSubjects ciPackageAddresses != []
        else builtins.elem entry.source requestedCiSources)
      testEntries;
      ciEntries = mergeDisjoint "CI job" [ciPackageEntries ciArtifactEntries ciTestEntries];
      selectablePackageEntries = lib.filterAttrs (_: entry: entry.instance.kind == "current") projectedPackageEntries;
      selectorSetFor = entry:
        if
          entry.scope
          == "python"
          || (entry.kind == "artifact" && lib.hasPrefix "wheel-" entry.artifactKind)
          || (entry.kind == "test" && (lib.hasPrefix "artifacts.registry." entry.subject || lib.hasPrefix "artifacts.wheel-" entry.subject))
        then "python"
        else if entry.scope == "wasix"
        then "packages"
        else "core";
      selectorSets =
        lib.mapAttrs (_: selected: map (entry: entry.address) selected)
        (lib.groupBy selectorSetFor (lib.attrValues ciEntries));
      derivationOf = entry: entry.build;
    in
      assert wasixShapesValid;
      assert pythonShapesValid;
      assert pythonPreferenceValid;
      assert projectValid;
      assert nativeInterfacesValid;
      assert subjectsValid;
      assert aliasesValid; {
        schemaVersion = schema.version;
        packages = packageViews;
        commands = commandsView;
        artifacts = artifactsView;
        harnesses = harnessesView;
        runners = runnersView;
        probes = probesView;
        tests = lib.mapAttrs (_: entry: entry.check) testEntries;
        catalog = {inherit entries;};
        ci = {
          sources = requestedCiSources;
          jobs = lib.mapAttrs (_: derivationOf) ciEntries;
          catalog = {
            inherit (project) schemaVersion;
            jobs = lib.mapAttrs (_: serializableEntry) ciEntries;
            packages = lib.mapAttrs (_: serializableEntry) selectablePackageEntries;
            selectors = {
              sets = selectorSets;
              groups = ci.groups or {};
            };
          };
        };
        internals.packageSets = {
          inherit nativeRaw wasixRaw pythonRaw;
        };
      };
  in
    lib.throwIf (invalidProjectionRules != [])
    "invalid projection rule(s): ${lib.concatStringsSep ", " invalidProjectionRules}"
    (lib.throwIf (unknownCiSources != [])
      "CI selects unknown Wasinix source(s): ${lib.concatStringsSep ", " unknownCiSources}"
      (lib.throwIf (invalidProjectTests != [])
        "invalid project test declaration(s): ${lib.concatStringsSep ", " invalidProjectTests}"
        (lib.throwIf (unknownProjectTestSources != [])
          "project tests select unknown Wasinix source(s): ${lib.concatStringsSep ", " unknownProjectTestSources}"
          project)));
}
