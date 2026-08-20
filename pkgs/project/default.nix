{
  lib,
  profiles,
  builtInExtension,
  crossSystemFor,
  configFor ? _scope: _variant: {},
  toolchainFor ? _project: {},
  commandsFor ? _project: {},
  artifactsFor ? _project: {},
  harnessesFor ? _project: {},
  checkRules ? {},
  pythonSetsFor ? _args: {},
  extendPythonSet ? packageSet: overlay: packageSet.overrideScope overlay,
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
    overlay =
      if builtins.isFunction declared
      then declared
      else if lib.isAttrs declared && declared.__wasinixPackageDirectory or false
      then
        projectLib.loadPackageOverlay {
          inherit contextFor;
          dir = declared.directory;
        }
      else throw "Wasinix extension '${extension.id}' overlay lane '${lane}' is not an overlay";
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
    overlay =
      if builtins.isFunction declared
      then declared enclosingContext.final enclosingContext.prev
      else if lib.isAttrs declared && declared.__wasinixPackageDirectory or false
      then
        projectLib.loadPackageOverlay {
          inherit contextFor;
          dir = declared.directory;
        }
      else throw "Wasinix extension '${extension.id}' Python lane is not an overlay";
  in
    projectLib.registerOverlay {
      inherit overlay;
      source = extension.id;
    };

  packageEntry = {
    address,
    package,
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
    inherit address package scope variant;
    inherit (metadata) source lineage instance;
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

  checksFor = context: entry: let
    merge = state: ruleName: rule: let
      result = projectLib.callWith (context // {inherit entry;}) rule;
      invalid = lib.filterAttrs (_: check: !lib.isDerivation check) result;
      duplicates = lib.intersectLists (lib.attrNames state) (lib.attrNames result);
    in
      lib.throwIf (!lib.isAttrs result)
      "check rule '${ruleName}' must return an attribute set"
      (lib.throwIf (invalid != {})
        "check rule '${ruleName}' returned non-derivation check(s): ${lib.concatStringsSep ", " (lib.attrNames invalid)}"
        (lib.throwIf (duplicates != [])
          "check rules returned duplicate check(s) for ${entry.address}: ${lib.concatStringsSep ", " duplicates}"
          (state // result)));
  in
    lib.foldlAttrs merge {} checkRules;

  validateVariantShapes = label: extensionIds: packageSets: let
    variants = lib.attrNames packageSets;
    namesFor = source: variant:
      lib.attrNames (lib.filterAttrs (_: package:
        (projectLib.packageMetadata package).source or null == source)
      (projectLib.registeredPackages packageSets.${variant}));
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
  inherit (projectLib) extendPackage;

  loadPackageOverlays = directories:
    lib.mapAttrs (_: directory: {
      __wasinixPackageDirectory = true;
      inherit directory;
    })
    directories;

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
        replayed = lib.foldl' (previous: overlay:
          previous
          // (projectLib.registerOverlay {
              inherit overlay source;
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

      packageSetProjection = scope: finalSet:
        lib.genAttrs (projectLib.registeredNames finalSet)
        (name: packageViewFor scope finalSet name finalSet.${name});

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

      contextFor = scope: variant: enclosingPkgs: {final, ...}:
        {
          packages = {
            inherit native wasix python preferred;
            toolchain = {};
            sameProfile = final // packageSetProjection scope final;
          };
          commands = commandsView;
          artifacts = artifactsView;
          harnesses = harnessesView;
          inherit (projectLib) extendPackage mergeScript;
        }
        // lib.optionalAttrs (enclosingPkgs != null) {pkgs = enclosingPkgs;};

      nativeRaw = importNixpkgs {
        localSystem = {inherit system;};
        config = configFor "native" {};
        overlays = overlaysFor (contextFor "native" {} null) ["shared" "native"];
      };

      wasixRaw =
        lib.mapAttrs (
          profile: spec:
            importNixpkgs {
              localSystem = {inherit system;};
              crossSystem = crossSystemFor profile spec;
              config = configFor "wasix" {inherit profile;};
              overlays = overlaysFor (contextFor "wasix" {inherit profile;} null) ["shared" "wasix"];
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

      native = packageSetView "native" nativeRaw;
      wasix = lib.mapAttrs (profile: packageSet:
        lib.filterAttrs (_: package: builtins.elem profile (supportedProfilesFor package))
        (packageSetView "wasix" packageSet))
      wasixRaw;
      python = lib.mapAttrs (_: packageSet: packageSetView "python" packageSet) pythonRaw;
      allWasixNames = lib.unique (lib.concatMap lib.attrNames (lib.attrValues wasix));
      preferred = lib.genAttrs allWasixNames (name: let
        defaultProfile = profiles.defaultProfileName or null;
        packageAtDefault = wasixRaw.${defaultProfile}.${name};
        declaredProfile = preferredProfileFor packageAtDefault;
      in
        lib.throwIf (defaultProfile == null)
        "the WASIX profile inventory does not define defaultProfileName"
        (lib.throwIf (!(wasix.${declaredProfile} ? ${name}))
          "${name}: preferred WASIX profile '${declaredProfile}' is unavailable"
          wasix.${declaredProfile}.${name}));

      packageViews = {
        inherit native wasix python preferred;
        toolchain = {};
      };
      toolchainView = toolchainFor project;
      commandsView = commandsFor project;
      artifactsView = artifactsFor project;
      harnessesView = harnessesFor project;
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
          inherit address package;
          scope = "native";
          variant = {};
        }))
      native;
      wasixEntries = lib.concatMapAttrs (profile: packages:
        lib.mapAttrs' (name: package: let
          address = projectLib.address "packages" ["wasix" profile name];
        in
          lib.nameValuePair address (packageEntry {
            inherit address package;
            scope = "wasix";
            variant = {inherit profile;};
          }))
        packages)
      wasix;
      pythonEntries = lib.concatMapAttrs (interpreter: packages:
        lib.mapAttrs' (name: package: let
          address = projectLib.address "packages" ["python" interpreter name];
        in
          lib.nameValuePair address (packageEntry {
            inherit address package;
            scope = "python";
            variant = {inherit interpreter;};
          }))
        packages)
      python;
      currentPackageEntries = nativeEntries // wasixEntries // pythonEntries;
      historyEntries = lib.concatMapAttrs (_: entry:
        lib.mapAttrs' (version: package: let
          address = "${entry.address}.versions${projectLib.addressSegment version}";
        in
          lib.nameValuePair address (packageEntry {
            inherit address package;
            inherit (entry) scope variant;
          }))
        entry.package.versions)
      currentPackageEntries;
      packageEntries = currentPackageEntries // historyEntries;
      testEntries = lib.concatMapAttrs (_: entry:
        lib.mapAttrs' (name: check: let
          address = "tests.${entry.address}${projectLib.addressSegment name}";
          metadata = projectLib.packageMetadata check;
          checkPolicy = builtins.removeAttrs metadata projectLib.machineMetadata;
          subjectCi = entry.policy.ci or {};
          checkCi = checkPolicy.ci or {};
        in
          lib.nameValuePair address {
            kind = "test";
            inherit address check;
            inherit (entry) source lineage scope variant instance;
            subject = entry.address;
            policy =
              checkPolicy
              // {
                ci =
                  subjectCi
                  // checkCi
                  // {tags = lib.unique ((subjectCi.tags or []) ++ (checkCi.tags or []));};
              };
          })
        (checksFor (contextForEntry entry) entry))
      packageEntries;
      entries = packageEntries // testEntries;
      ciPackageEntries = lib.filterAttrs (_: entry:
        builtins.elem entry.source requestedCiSources
        && (
          entry.scope
          != "wasix"
          || builtins.elem entry.variant.profile (ciProfilesFor entry.package)
        ))
      packageEntries;
      ciPackageAddresses = lib.attrNames ciPackageEntries;
      ciTestEntries = lib.filterAttrs (_: entry:
        builtins.elem entry.subject ciPackageAddresses)
      testEntries;
      ciEntries = ciPackageEntries // ciTestEntries;
      derivationOf = entry:
        if entry.kind == "package"
        then entry.package
        else entry.check;
    in
      assert wasixShapesValid;
      assert pythonShapesValid;
      assert wasixHistoryValid;
      assert pythonHistoryValid; {
        schemaVersion = schema.version;
        packages = packageViews;
        toolchain = toolchainView;
        commands = commandsView;
        artifacts = artifactsView;
        harnesses = harnessesView;
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
