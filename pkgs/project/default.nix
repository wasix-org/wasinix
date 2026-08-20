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
}: let
  projectLib = import ./lib.nix {inherit lib;};
  schema = builtins.fromJSON (builtins.readFile ../../schema/project.json);

  validateExtension = extension: let
    id = extension.id or null;
    invalidLanes = lib.subtractLists ["shared" "native" "wasix" "python"] (lib.attrNames (extension.overlays or {}));
  in
    lib.throwIf (
      !builtins.isString id
      || builtins.match "[a-z0-9][a-z0-9._-]*" id == null
    )
    "Wasinix extension IDs must use lowercase letters, numbers, '.', '_', or '-'"
    (lib.throwIf (invalidLanes != [])
      "Wasinix extension '${id}' has unknown overlay lane(s): ${lib.concatStringsSep ", " invalidLanes}"
      extension);

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

  packageView = package: package // {versions = {};};

  packageEntry = {
    address,
    package,
    scope,
    variant,
  }: let
    metadata = projectLib.packageMetadata package;
  in {
    kind = "package";
    inherit address package scope variant;
    inherit (metadata) source lineage instance;
    policy = builtins.removeAttrs metadata ["source" "lineage" "instance"];
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
    requestedCiSources = ci.sources or (map (extension: extension.id) extensions);
    unknownCiSources = lib.subtractLists extensionIds requestedCiSources;

    overlaysFor = contextFor: lanes:
      lib.concatMap (
        extension:
          map (lane:
            laneOverlay {
              inherit contextFor extension lane;
            })
          lanes
      )
      allExtensions;

    project = let
      contextFor = scope: variant: enclosingPkgs: {final, ...}:
        project.context
        // {
          packages =
            project.packages
            // {
              sameProfile =
                final
                // lib.mapAttrs (_: packageView) (projectLib.registeredPackages final);
            };
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

      native = lib.mapAttrs (_: packageView) (projectLib.registeredPackages nativeRaw);
      wasix = lib.mapAttrs (_: packageSet: lib.mapAttrs (_: packageView) (projectLib.registeredPackages packageSet)) wasixRaw;
      allWasixNames = lib.unique (lib.concatMap lib.attrNames (lib.attrValues wasix));
      preferred = lib.genAttrs allWasixNames (name: let
        defaultProfile = profiles.defaultProfileName or null;
        packageAtDefault = wasix.${defaultProfile}.${name} or null;
        declaredProfile = ((packageAtDefault.passthru or {}).wasix or {}).preferredProfile or defaultProfile;
      in
        lib.throwIf (defaultProfile == null)
        "the WASIX profile inventory does not define defaultProfileName"
        (lib.throwIf (!(wasix.${declaredProfile} ? ${name}))
          "${name}: preferred WASIX profile '${declaredProfile}' is unavailable"
          wasix.${declaredProfile}.${name}));

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
      packageEntries = nativeEntries // wasixEntries;
      testEntries = lib.concatMapAttrs (_: entry:
        lib.mapAttrs' (name: check: let
          address = "tests.${entry.address}${projectLib.addressSegment name}";
          metadata = projectLib.packageMetadata check;
        in
          lib.nameValuePair address {
            kind = "test";
            inherit address check;
            inherit (entry) source lineage scope variant instance;
            subject = entry.address;
            policy = builtins.removeAttrs metadata ["source" "lineage" "instance"];
          })
        (checksFor project.context entry))
      packageEntries;
      entries = packageEntries // testEntries;
      ciEntries = lib.filterAttrs (_: entry: builtins.elem entry.source requestedCiSources) entries;
      derivationOf = entry:
        if entry.kind == "package"
        then entry.package
        else entry.check;
    in {
      schemaVersion = schema.version;
      packages = {
        inherit native wasix preferred;
        toolchain = {};
        python = {};
      };
      toolchain = toolchainFor project;
      commands = commandsFor project;
      artifacts = artifactsFor project;
      harnesses = harnessesFor project;
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
      context = {
        inherit (project) packages commands artifacts harnesses;
        inherit (projectLib) extendPackage mergeScript;
      };
      internals.packageSets = {
        inherit nativeRaw wasixRaw;
      };
    };
  in
    lib.throwIf (unknownCiSources != [])
    "CI selects unknown Wasinix source(s): ${lib.concatStringsSep ", " unknownCiSources}"
    project;
}
