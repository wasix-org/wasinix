{
  lib,
  profiles,
  builtInExtension,
  crossSystemFor,
  configFor ? _args: {},
  setOverlaysFor ? _args: [],
  nativePackageInterfacesFor ? _args: {},
  harnessesFor ? _args: {},
  runnersFor ? _args: {},
  projectionRules ? {},
  pythonSetsFor ? _args: {},
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
  rebasePackage ? (import ./history.nix {inherit lib;}).rebasePackage,
}: let
  projectLib = import ./lib.nix {inherit lib;};
  schema = builtins.fromJSON (builtins.readFile ../../schema/project.json);

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
  }: let
    declared = (extension.overlays or {}).${lane} or (_final: _prev: {});
    rawOverlay =
      if builtins.isFunction declared
      then declared
      else if lib.isAttrs declared && declared.__wasinixPackageDirectory or false
      then
        projectLib.loadPackageOverlay {
          inherit contextFor;
          dir = declared.directory;
        }
      else throw "Wasinix extension '${extension.id}' overlay lane '${lane}' is not an overlay";
    overlay = final: previous:
      lib.optionalAttrs (
        lane
        != "wasix"
        || previous.stdenv.hostPlatform.isWasix or false
      ) (rawOverlay final previous);
  in
    projectLib.registerOverlay {
      inherit overlay;
      source = extension.id;
    };

  captureExtensionContext = extension: final: prev: {
    ${projectLib.extensionContextsAttr} =
      (prev.${projectLib.extensionContextsAttr} or {})
      // {${extension.id} = {inherit final prev;};};
  };

  pythonLaneOverlay = {
    contextFor,
    enclosingPkgs,
    extension,
  }: let
    declared = (extension.overlays or {}).python;
    enclosingContext = enclosingPkgs.${projectLib.extensionContextsAttr}.${extension.id};
    rawOverlay =
      if builtins.isFunction declared
      then declared enclosingContext.final enclosingContext.prev
      else if lib.isAttrs declared && declared.__wasinixPackageDirectory or false
      then
        projectLib.loadPackageOverlay {
          inherit contextFor;
          dir = declared.directory;
        }
      else throw "Wasinix extension '${extension.id}' Python lane is not an overlay";
    overlay = final: previous:
      lib.optionalAttrs (previous.python.stdenv.hostPlatform.isWasix or false)
      (lib.mapAttrs (_: value:
        if lib.isDerivation value
        then repairPythonPackage value
        else value)
      (rawOverlay final previous));
  in
    projectLib.registerOverlay {
      inherit overlay;
      source = extension.id;
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
    basePolicy = builtins.removeAttrs metadata projectLib.machineMetadata;
    policy =
      if metadata.instance.kind == "history"
      then
        basePolicy
        // {
          ci =
            (basePolicy.ci or {})
            // {tags = lib.unique ((basePolicy.ci.tags or []) ++ ["history-tests"]);};
        }
      else basePolicy;
  in {
    kind = "package";
    inherit address name package preferred projectionPath scope variant;
    inherit (metadata) definition source lineage instance;
    inherit policy;
  };

  serializableEntry = entry:
    {
      inherit (entry) kind address source lineage scope variant instance;
      policy = {
        aliases = entry.policy.aliases or [];
        shipped = entry.policy.shipped or false;
        ci = entry.policy.ci or {};
        retention = entry.policy.retention or null;
      };
    }
    // lib.optionalAttrs (entry ? subject) {inherit (entry) subject;};

  projectionsFor = context: entry: let
    namespaces = ["artifacts" "commands" "tests"];
    resultFor = ruleName: rule: let
      result = projectLib.callWith (context // {inherit entry;}) rule;
      unknown = lib.subtractLists namespaces (lib.attrNames result);
    in
      lib.throwIf (!lib.isAttrs result)
      "projection rule '${ruleName}' must return an attribute set"
      (lib.throwIf (unknown != [])
        "projection rule '${ruleName}' returned unknown namespace(s): ${lib.concatStringsSep ", " unknown}"
        result);
    results = lib.mapAttrs resultFor projectionRules;
    validCommand = name: command:
      lib.isAttrs command
      && builtins.isString (command.name or null)
      && command.name == name
      && lib.isDerivation (command.artifact or null)
      && builtins.isString (command.entrypoint or null);
    invalidFor = namespace: values:
      if namespace == "artifacts"
      then lib.filterAttrs (_: artifact: !lib.isDerivation artifact) values
      else if namespace == "commands"
      then lib.filterAttrs (name: command: !validCommand name command) values
      else lib.filterAttrs (_: test: !lib.isDerivation test) values;
    mergeNamespace = namespace: state: ruleName: result: let
      values = result.${namespace} or {};
      invalid = invalidFor namespace values;
      duplicates = lib.intersectLists (lib.attrNames state) (lib.attrNames values);
      singular =
        if namespace == "artifacts"
        then "artifact"
        else if namespace == "commands"
        then "command"
        else "test";
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

  mkProject = {
    system,
    importNixpkgs,
    extensions ? [],
    ci ? {},
  }: let
    allExtensions = ensureUniqueExtensions (map validateExtension ([builtInExtension] ++ extensions));
    extensionIds = map (extension: extension.id) allExtensions;
    historyTables = lib.listToAttrs (map (extension:
      lib.nameValuePair extension.id
      (lib.mapAttrs (_: path: builtins.fromJSON (builtins.readFile path)) (extension.history or {})))
    allExtensions);
    requestedCiSources = ci.sources or (map (extension: extension.id) extensions);
    unknownCiSources = lib.subtractLists extensionIds requestedCiSources;

    overlaysFor = contextFor: lanes:
      lib.concatMap (
        extension:
          [
            (captureExtensionContext extension)
          ]
          ++ map (lane:
            laneOverlay {
              inherit contextFor extension lane;
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

      historySpecsFor = scope: name: package: let
        source = (projectLib.packageMetadata package).source;
      in
        ((historyTables.${source} or {}).${scope} or {}).${name} or {};

      replayHistory = {
        finalSet,
        name,
        package,
        spec,
        version,
      }: let
        metadata = projectLib.packageMetadata package;
        source = metadata.source;
        baseSet = metadata.${projectLib.historyBaseAttr};
        overlays = metadata.${projectLib.historyOverlaysAttr};
        rebased =
          lib.throwIf (!(baseSet ? ${name}))
          "${source}.${name}: history requires a preceding package to rebase"
          (rebasePackage version spec baseSet.${name});
        initial = baseSet // {${name} = rebased;};
        replayed = lib.foldl' (previous: layer:
          previous
          // (projectLib.registerOverlay {
              inherit (layer) definition overlay;
              inherit source;
              instanceFor = resultName: result:
                if resultName == name
                then {
                  kind = "history";
                  inherit version;
                }
                else
                  (projectLib.packageMetadata
                    result).instance or {
                    kind = "current";
                    version = toString (result.version or result.name);
                  };
            }
            finalSet
            previous))
        initial
        overlays;
        result = replayed.${name};
      in
        lib.throwIf (toString result.version != version)
        "${source}.${name}: history requested ${version}, but replay produced ${toString result.version}"
        result;

      packageViewFor = scope: finalSet: name: package:
        package
        // {
          versions = lib.mapAttrs (version: spec:
            (replayHistory {
              inherit finalSet name package spec version;
            })
            // {versions = {};})
          (historySpecsFor scope name package);
        };

      packageSetView = scope: finalSet:
        lib.mapAttrs (name: package: packageViewFor scope finalSet name package)
        (projectLib.registeredPackages finalSet);

      projectedPackageFor = scope: variant: finalSet: name: rawPackage: let
        package = packageViewFor scope finalSet name rawPackage;
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

      historyDeclarationsFor = scope:
        lib.concatMap (extension:
          map (name: {
            inherit name;
            source = extension.id;
          })
          (lib.attrNames ((historyTables.${extension.id} or {}).${scope} or {})))
        allExtensions;

      validateHistory = scope: packageSet: let
        declarations = historyDeclarationsFor scope;
        grouped = lib.groupBy (declaration: declaration.name) declarations;
        duplicates = lib.attrNames (lib.filterAttrs (_: values: lib.length values > 1) grouped);
        invalid = lib.filter (declaration: let
          package = packageSet.${declaration.name} or null;
        in
          package
          == null
          || (projectLib.packageMetadata package).source or null != declaration.source)
        declarations;
      in
        lib.throwIf (duplicates != [])
        "multiple Wasinix sources retain history for ${scope} package(s): ${lib.concatStringsSep ", " duplicates}"
        (lib.throwIf (invalid != [])
          "${scope} history does not match its current package owner: ${lib.concatStringsSep ", " (map (declaration: "${declaration.source}.${declaration.name}") invalid)}"
          true);

      contextFor = scope: variant: enclosingPkgs: {final, ...}: {
        inherit lib;
        packages = {
          inherit native wasix python preferred;
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
        inherit (projectLib) buildHostPypaTools dropFlagsByPrefix dropInputsByName dropInputsByNameInfix dropPatchesByNameInfix dropSphinxDocs extendPackage linkInputs mergeScript replaceInputsByName wasmRename;
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
          ++ overlaysFor (contextFor "native" {} null) ["shared" "native"];
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
                ++ overlaysFor (contextFor "wasix" {inherit profile;} null) ["shared" "wasix"];
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
                inherit extension;
              })
            else packageSet
        )
        spec.packageSet
        allExtensions))
      pythonSpecs;

      wasixShapesValid = validateVariantShapes "WASIX" extensionIds wasixRaw;
      pythonShapesValid = validateVariantShapes "Python" extensionIds pythonRaw;
      wasixHistoryValid = lib.all (packageSet: validateHistory "wasix" packageSet) (lib.attrValues wasixRaw);
      pythonHistoryValid = lib.all (packageSet: validateHistory "python" packageSet) (lib.attrValues pythonRaw);

      nativePackageInterfaces = nativePackageInterfacesFor {
        inherit project nativeRaw wasixRaw pythonRaw;
      };
      unknownInterfacePackages = lib.subtractLists (projectLib.registeredNames nativeRaw) (lib.attrNames nativePackageInterfaces);
      nativeInterfacesValid =
        lib.throwIf (unknownInterfacePackages != [])
        "native package interfaces target unknown package(s): ${lib.concatStringsSep ", " unknownInterfacePackages}"
        true;
      baseNative = lib.mapAttrs (name: package:
        package // (nativePackageInterfaces.${name} or {}))
      (packageSetView "native" nativeRaw);
      baseWasix = lib.mapAttrs (profile: packageSet:
        lib.filterAttrs (_: package: builtins.elem profile (supportedProfilesFor package))
        (packageSetView "wasix" packageSet))
      wasixRaw;
      basePython = lib.mapAttrs (_: packageSet: packageSetView "python" packageSet) pythonRaw;
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
        contextFor entry.scope entry.variant selected.enclosing {inherit (selected) final;};

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
      historyEntries = lib.concatMapAttrs (_: entry:
        lib.mapAttrs' (version: package: let
          address = "${entry.address}.versions${projectLib.addressSegment version}";
        in
          lib.nameValuePair address (packageEntry {
            inherit address package;
            inherit (entry) name preferred;
            projectionPath = entry.projectionPath ++ ["versions" version];
            inherit (entry) scope variant;
          }))
        entry.package.versions)
      currentPackageEntries;
      packageEntries = currentPackageEntries // historyEntries;
      inheritedPolicy = subject: derivation: let
        own = builtins.removeAttrs (projectLib.packageMetadata derivation) projectLib.machineMetadata;
        subjectCi = subject.policy.ci or {};
        ownCi = own.ci or {};
      in
        own
        // {
          ci =
            subjectCi
            // ownCi
            // {tags = lib.unique ((subjectCi.tags or []) ++ (ownCi.tags or []));};
        };
      mergeDisjoint = label: left: right: let
        duplicates = lib.intersectLists (lib.attrNames left) (lib.attrNames right);
      in
        lib.throwIf (duplicates != [])
        "duplicate ${label} address(es): ${lib.concatStringsSep ", " duplicates}"
        (left // right);
      mergeProjectionCollections = left: right: {
        artifacts = mergeDisjoint "artifact" left.artifacts right.artifacts;
        commands = mergeDisjoint "command" left.commands right.commands;
        tests = mergeDisjoint "test" left.tests right.tests;
      };
      emptyProjectionCollection = {
        artifacts = {};
        commands = {};
        tests = {};
      };
      projectEntry = baseEntry: let
        outputs = projectionsFor (contextForEntry entry) entry;
        artifactNodes = lib.mapAttrs (kind: artifact:
          projectEntry {
            kind = "artifact";
            address = projectLib.address "artifacts" ([kind] ++ baseEntry.projectionPath);
            artifactKind = kind;
            inherit artifact;
            inherit (baseEntry) name preferred projectionPath definition source lineage scope variant instance;
            subject = baseEntry.address;
            packageSubject = baseEntry.packageSubject or baseEntry.address;
            policy = inheritedPolicy baseEntry artifact;
          })
        outputs.artifacts;
        relativeArtifacts = lib.mapAttrs (_: node: node.value) artifactNodes;
        versions = lib.optionalAttrs (baseEntry.kind == "package" && baseEntry.instance.kind == "current") {
          versions = lib.mapAttrs (version: _:
            projectedPackageNodes.${"${baseEntry.address}.versions${projectLib.addressSegment version}"}.value)
          baseEntry.package.versions;
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
        ownCommands = lib.mapAttrs' (name: command: let
          projectionPath =
            [name]
            ++ lib.optionals (baseEntry.instance.kind == "history") ["versions" baseEntry.instance.version];
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
            inherit (baseEntry) definition source lineage scope variant instance;
            subject = baseEntry.address;
            packageSubject = baseEntry.packageSubject or baseEntry.address;
            policy = inheritedPolicy baseEntry check;
          })
        outputs.tests;
        descendants = lib.foldl' mergeProjectionCollections emptyProjectionCollection (map (node: node.descendants) (lib.attrValues artifactNodes));
      in {
        inherit entry value;
        descendants = mergeProjectionCollections descendants {
          artifacts = ownArtifacts;
          commands = ownCommands;
          tests = ownTests;
        };
      };
      projectedPackageNodes = lib.mapAttrs (_: projectEntry) packageEntries;
      projectedPackageEntries = lib.mapAttrs (_: node: node.entry) projectedPackageNodes;
      projected = lib.foldl' mergeProjectionCollections emptyProjectionCollection (map (node: node.descendants) (lib.attrValues projectedPackageNodes));
      artifactEntries = projected.artifacts;
      commandEntries = projected.commands;
      testEntries = projected.tests;
      entries = lib.foldl' (mergeDisjoint "catalog") {} [projectedPackageEntries artifactEntries commandEntries testEntries];
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
      (lib.attrValues commandEntries));
      ciPackageEntries = lib.filterAttrs (_: entry:
        builtins.elem entry.source requestedCiSources
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
        builtins.elem entry.packageSubject ciPackageAddresses)
      testEntries;
      ciEntries = lib.foldl' (mergeDisjoint "CI job") {} [ciPackageEntries ciArtifactEntries ciTestEntries];
      derivationOf = entry:
        if entry.kind == "package"
        then entry.package
        else if entry.kind == "artifact"
        then entry.artifact
        else entry.check;
    in
      assert wasixShapesValid;
      assert pythonShapesValid;
      assert wasixHistoryValid;
      assert pythonHistoryValid;
      assert nativeInterfacesValid; {
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
          };
        };
        internals.packageSets = {
          inherit nativeRaw wasixRaw pythonRaw;
        };
      };
  in
    lib.throwIf (unknownCiSources != [])
    "CI selects unknown Wasinix source(s): ${lib.concatStringsSep ", " unknownCiSources}"
    project;
}
