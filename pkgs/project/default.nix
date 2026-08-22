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
    extension,
    lane,
    scope,
    variant,
  }: let
    declared = (extension.overlays or {}).${lane} or (_final: _prev: {});
    rawOverlay = declaredOverlayFor {
      inherit contextFor declared extension;
      label = "overlay lane '${lane}'";
    };
    overlay = final: previous:
      lib.mapAttrs (name: value:
        if lib.isDerivation value
        then
          packageTransformFor {
            inherit scope variant;
            packageSet = previous;
          }
          name
          value
        else value)
      (lib.optionalAttrs (
        lane
        != "wasix"
        || previous.stdenv.hostPlatform.isWasix or false
      ) (rawOverlay final previous));
  in
    registerExtensionOverlay {inherit declared extension overlay;};

  captureExtensionContext = extension: final: prev: {
    ${projectLib.extensionContextsAttr} =
      (prev.${projectLib.extensionContextsAttr} or {})
      // {${extension.id} = {inherit final prev;};};
  };

  pythonLaneOverlay = {
    contextFor,
    enclosingPkgs,
    extension,
    interpreter,
  }: let
    declared = (extension.overlays or {}).python;
    enclosingContext = enclosingPkgs.${projectLib.extensionContextsAttr}.${extension.id};
    rawOverlay = declaredOverlayFor {
      inherit contextFor declared extension;
      label = "Python lane";
      applyFunction = function: function enclosingContext.final enclosingContext.prev;
      extendPackageFor = extendPythonPackage;
    };
    overlay = final: previous:
      lib.optionalAttrs (previous.python.stdenv.hostPlatform.isWasix or false)
      (lib.mapAttrs (name: value:
        if lib.isDerivation value
        then
          packageTransformFor {
            scope = "python";
            variant = {inherit interpreter;};
            packageSet = previous;
          }
          name
          (repairPythonPackage value)
        else value)
      (rawOverlay final previous));
  in
    registerExtensionOverlay {inherit declared extension overlay;};

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
    policy = builtins.removeAttrs metadata projectLib.machineMetadata;
  in {
    kind = "package";
    inherit address name package preferred projectionPath scope variant;
    inherit (metadata) definition source lineage instance;
    inherit policy;
  };

  serializableEntry = entry:
    {
      inherit (entry) kind address name source lineage scope variant instance;
      policy = {
        aliases = aliasAddressesFor entry;
        shipped = entry.policy.shipped or false;
        ci = entry.policy.ci or {};
        publication = entry.policy.publication or {};
        retention = entry.policy.retention or null;
      };
    }
    // lib.optionalAttrs (entry ? artifactKind) {inherit (entry) artifactKind;}
    // lib.optionalAttrs (entry ? packageSubject) {inherit (entry) packageSubject;}
    // lib.optionalAttrs (entry ? subject) {inherit (entry) subject;}
    // lib.optionalAttrs (entry ? testName) {inherit (entry) testName;}
    // lib.optionalAttrs (entry.kind == "package" && entry.scope == "wasix") {
      spotTarget = "${entry.variant.profile}.${entry.name}";
      spotOwner = entry.name;
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
        else rule.project or null;
      unknownDeclared = lib.subtractLists knownNamespaces declaredNamespaces;
      applies = lib.intersectLists namespaces declaredNamespaces != [];
      result =
        if applies && builtins.isFunction function
        then projectLib.callWith (context // {inherit entry;}) function
        else {};
      unknown = lib.subtractLists declaredNamespaces (lib.attrNames result);
    in
      lib.throwIf (declaredNamespaces == [])
      "projection rule '${ruleName}' must declare at least one namespace"
      (lib.throwIf (unknownDeclared != [])
        "projection rule '${ruleName}' declares unknown namespace(s): ${lib.concatStringsSep ", " unknownDeclared}"
        (lib.throwIf (!builtins.isFunction function)
          "projection rule '${ruleName}' has no project function"
          (lib.throwIf (!lib.isAttrs result)
            "projection rule '${ruleName}' must return an attribute set"
            (lib.throwIf (unknown != [])
              "projection rule '${ruleName}' returned undeclared namespace(s): ${lib.concatStringsSep ", " unknown}"
              result))));
    results = lib.mapAttrs resultFor projectionRules;
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
          ++ map (lane:
            laneOverlay {
              inherit contextFor extension lane scope variant;
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

      packageSetView = scope: variant: finalSet:
        projectLib.registeredPackages finalSet;

      projectedPackageFor = scope: variant: finalSet: name: rawPackage: let
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

      contextFor = scope: variant: enclosingPkgs: {final, ...}: {
        inherit lib;
        packages = {
          native = nativeForContext;
          inherit wasix python preferred;
          sameProfile = projectedPackageSet scope variant final;
        };
        commands = commandsView;
        artifacts = artifactsView;
        harnesses = harnessesView;
        runners = runnersView;
        inherit profileSets;
        inherit (profiles) profileOf;
        profileTraitsOf = platform: profiles.sysrootEncodings.${profiles.profileOf platform};
        pkgs =
          if enclosingPkgs != null
          then enclosingPkgs
          else if scope == "wasix"
          then nativeRaw
          else final;
        inherit (projectLib) buildHostPypaTools dropFlagsByPrefix dropInputsByName dropInputsByNameInfix dropPatchesByNameInfix dropSphinxDocs extendPackage linkInputs mergeScript packageForEntry replaceInputsByName wasmRename;
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
                }
                ++ overlaysFor (contextFor "wasix" {inherit profile;} null) "wasix" {inherit profile;} ["shared" "wasix"];
            }
        )
        profiles.profiles;

      pythonSpecs = pythonSetsFor {inherit project nativeRaw wasixRaw;};
      pythonRaw = lib.mapAttrs (interpreter: spec: (lib.foldl' (
          packageSet: extension:
            if (extension.overlays or {}) ? python
            then
              extendPythonSet packageSet (pythonLaneOverlay {
                contextFor = contextFor "python" {inherit interpreter;} spec.pkgs;
                enclosingPkgs = spec.pkgs;
                inherit extension interpreter;
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
        })
        // {
          packageSets = {
            native = nativeRaw;
            wasix = wasixRaw;
            python = pythonRaw;
            preferred = lib.genAttrs allWasixNames (name: let
              profile = preferredProfileNameFor name;
            in
              wasixRaw.${profile}.${name});
          };
        };

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
          policy = {
            aliases = [];
            shipped = false;
            ci = test.ci or {};
            publication = {};
            retention = null;
          };
        })
      projectTests;
      inheritedPolicy = subject: derivation: let
        own = builtins.removeAttrs (projectLib.packageMetadata derivation) projectLib.machineMetadata;
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
        };
        outputs = projectionsFor {
          context = projectionContext;
          inherit entry;
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
              inherit artifact projectionPath;
              inherit (baseEntry) name preferred definition source lineage scope variant instance;
              subject = baseEntry.address;
              packageSubject = baseEntry.packageSubject or baseEntry.address;
              policy = inheritedPolicy baseEntry artifact;
            }
            // lib.optionalAttrs (!lib.isDerivation declared && declared ? name) {inherit (declared) name;}))
        outputs.artifacts;
        relativeArtifacts = lib.mapAttrs (_: node: node.value) artifactNodes;
        versions = lib.optionalAttrs (versionNodes != {}) {
          versions = lib.mapAttrs (_: node: node.value) versionNodes;
        };
        relative = {
          artifacts = relativeArtifacts;
          inherit (outputs) commands tests;
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
            packageSubject = baseEntry.packageSubject or baseEntry.address;
            policy = baseEntry.policy;
          })
        outputs.commands;
        ownTests = lib.mapAttrs' (name: check: let
          address = "tests.${baseEntry.address}${projectLib.addressSegment name}";
        in
          lib.nameValuePair address {
            kind = "test";
            inherit address check;
            inherit (baseEntry) name;
            testName = name;
            inherit (baseEntry) definition source lineage scope variant instance;
            subject = baseEntry.address;
            packageSubject = baseEntry.packageSubject or baseEntry.address;
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
      projectedPackageNodes = lib.mapAttrs (_: projectEntry) currentPackageEntries;
      projected = mergeProjectionCollections (map (node: node.descendants) (lib.attrValues projectedPackageNodes));
      projectedPackageEntries =
        lib.mapAttrs (_: node: node.entry) projectedPackageNodes
        // projected.packages;
      artifactEntries = projected.artifacts;
      commandEntries = projected.commands;
      testEntries = mergeDisjoint "test" [projected.tests projectTestEntries];
      entries = mergeDisjoint "catalog" [projectedPackageEntries artifactEntries commandEntries testEntries];
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
        inherit native wasix python preferred;
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
        builtins.elem entry.packageSubject ciPackageAddresses)
      artifactEntries;
      ciTestEntries = lib.filterAttrs (_: entry:
        if entry ? packageSubject
        then builtins.elem entry.packageSubject ciPackageAddresses
        else builtins.elem entry.source requestedCiSources)
      testEntries;
      ciEntries = mergeDisjoint "CI job" [ciPackageEntries ciArtifactEntries ciTestEntries];
      selectorSetFor = entry:
        if
          entry.scope
          == "python"
          || (entry.kind == "artifact" && builtins.elem entry.artifactKind ["wheel-noarch" "wheel-py313" "wheel-py314"])
          || (entry.kind == "test" && (lib.hasPrefix "artifacts.registry." entry.subject || lib.hasPrefix "artifacts.wheel-" entry.subject))
        then "python"
        else if entry.scope == "wasix"
        then "packages"
        else "core";
      selectorSets =
        lib.mapAttrs (_: selected: map (entry: entry.address) selected)
        (lib.groupBy selectorSetFor (lib.attrValues ciEntries));
      derivationOf = entry:
        if entry.kind == "package"
        then entry.package
        else if entry.kind == "artifact"
        then entry.artifact
        else entry.check;
    in
      assert wasixShapesValid;
      assert pythonShapesValid;
      assert projectValid;
      assert nativeInterfacesValid;
      assert aliasesValid; {
        schemaVersion = schema.version;
        packages = packageViews;
        commands = commandsView;
        artifacts = artifactsView;
        harnesses = harnessesView;
        runners = runnersView;
        tests = lib.mapAttrs (_: entry: entry.check) testEntries;
        catalog = {inherit entries;};
        ci = {
          sources = requestedCiSources;
          jobs = lib.mapAttrs (_: derivationOf) ciEntries;
          catalog = {
            schemaVersion = project.schemaVersion;
            jobs = lib.mapAttrs (_: serializableEntry) ciEntries;
            selectors = {
              sets = selectorSets;
              groups = {};
            };
          };
        };
        internals.packageSets = {
          inherit nativeRaw wasixRaw pythonRaw;
        };
      };
  in
    lib.throwIf (unknownCiSources != [])
    "CI selects unknown Wasinix source(s): ${lib.concatStringsSep ", " unknownCiSources}"
    (lib.throwIf (invalidProjectTests != [])
      "invalid project test declaration(s): ${lib.concatStringsSep ", " invalidProjectTests}"
      (lib.throwIf (unknownProjectTestSources != [])
        "project tests select unknown Wasinix source(s): ${lib.concatStringsSep ", " unknownProjectTestSources}"
        project));
}
