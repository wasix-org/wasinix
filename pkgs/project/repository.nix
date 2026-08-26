{
  lib,
  project,
  revisionsFile,
  root,
  source,
  publication ? {},
}: let
  wasinixLib = import ../lib {inherit lib;};
  projectLib = import ./lib.nix {inherit lib;};
  registry = project.artifacts.registry.python or null;
  cargoRegistryArtifact = project.artifacts.registry.cargo-registry or null;
  ownedEntries = projectLib.entriesForSource project.catalog.entries source;

  subjectsOf = entries:
    lib.unique (lib.concatMap (entry: entry.packageSubjects or []) entries);
  entriesMatching = predicate:
    lib.filter predicate (lib.attrValues ownedEntries);

  firstChangelog = derivations:
    lib.findFirst (value: value != null) null
    (map (drv: let
      attempted = builtins.tryEval (drv.meta.changelog or null);
    in
      if attempted.success
      then attempted.value
      else null)
    derivations);
  informationFor = {
    kind,
    versionOf,
    changelogOf ? (drv: drv),
    derivations,
    identity,
    packageSubjects,
  }: {
    versions = lib.unique (map versionOf derivations);
    inherit identity kind packageSubjects;
    changelogs =
      lib.mapAttrs (_: values: firstChangelog (map changelogOf values))
      (lib.groupBy versionOf derivations);
    derivations = lib.mapAttrs (_: values:
      map (drv: builtins.unsafeDiscardStringContext drv.drvPath) values)
    (lib.groupBy versionOf derivations);
  };
  wheelDerivations = name:
    lib.concatMap (perInterpreter: lib.attrValues (perInterpreter.${name} or {}))
    (lib.attrValues registry.wheels);
  wheelInfo =
    if registry == null
    then {}
    else
      lib.mapAttrs' (name: _:
        lib.nameValuePair "artifacts.registry.python.wheels.${name}" (informationFor {
          kind = "wheel";
          identity = {inherit name;};
          versionOf = drv: drv.version;
          derivations = wheelDerivations name;
          packageSubjects = subjectsOf (entriesMatching (entry:
            entry.kind
            == "artifact"
            && lib.hasPrefix "wheel-" entry.artifactKind
            && entry.name == name));
        }))
      (lib.filterAttrs (name: _:
        entriesMatching (entry:
          entry.kind
          == "artifact"
          && lib.hasPrefix "wheel-" entry.artifactKind
          && entry.name == name)
        != [])
      registry.wheelVersions);
  webcInfo = lib.mapAttrs' (name: package:
    lib.nameValuePair "artifacts.webc.${name}" (informationFor {
      kind = "webc";
      identity = {
        inherit name;
        inherit (package.id) owner;
      };
      versionOf = drv: drv.id.baseVersion;
      derivations = [package] ++ builtins.attrValues (package.versions or {});
      packageSubjects = ownedEntries.${"artifacts.webc.${name}"}.packageSubjects;
    }))
  (lib.filterAttrs (name: _: builtins.hasAttr "artifacts.webc.${name}" ownedEntries) (project.artifacts.pkg or {}));
  cargoSubjects =
    if ownedEntries ? "artifacts.registry.cargo-registry"
    then ownedEntries."artifacts.registry.cargo-registry".packageSubjects
    else [];
  cargoInfo = lib.mapAttrs' (name: _:
    lib.nameValuePair "artifacts.registry.cargo-registry.crates.${name}" (informationFor {
      kind = "crate";
      identity = {inherit name;};
      versionOf = drv: drv.passthru.version;
      derivations = builtins.attrValues (cargoRegistryArtifact.crates.${name} or {});
      packageSubjects = cargoSubjects;
    }))
  (lib.optionalAttrs (cargoSubjects != [] && cargoRegistryArtifact != null) cargoRegistryArtifact.crateVersions);
  publicationInfo = wheelInfo // webcInfo // cargoInfo;

  packagesFrom = prefix: packages:
    lib.mapAttrs' (name: package: lib.nameValuePair "${prefix}.${name}" package)
    (lib.filterAttrs (_: package: (package.passthru.wasinix.source or null) == source) packages);
  updateCandidates =
    packagesFrom "packages.native" project.packages.native
    // packagesFrom "packages.wasix.preferred" project.packages.wasix.preferred
    // lib.optionalAttrs (project.packages.python ? preferred)
    (packagesFrom "packages.python.preferred" project.packages.python.preferred);
  commandDrvsOf = lib.concatMap (value:
    if lib.isDerivation value
    then [value.drvPath]
    else builtins.attrNames (builtins.getContext (toString value)));
  updateScripts = let
    srcRoot = toString root;
    updateOwnership = package: let
      declared = package.passthru.wasinix.ownership or {};
      source = package.passthru.wasinix.source or null;
      registry = project.ownership.${source}.maintainers or {};
      people = field: let
        values = declared.${field} or [];
        known = builtins.attrValues registry;
      in
        lib.throwIf (!lib.isList values)
        "package ownership.${field} must be a list"
        (lib.throwIf (!(lib.all (value: builtins.elem value known) values))
          "package ownership.${field} contains a maintainer outside source '${toString source}'"
          values);
    in
      lib.throwIf (!lib.isAttrs declared || lib.isDerivation declared)
      "package ownership must be an attribute set"
      (lib.throwIf (lib.subtractLists ["assignees" "reviewers"] (lib.attrNames declared) != [])
        "package ownership has unknown field(s)"
        {
          assignees = people "assignees";
          reviewers = people "reviewers";
        });
    scriptFor = address: package: let
      declaration = package.passthru.updateScript or null;
      commandValues =
        if lib.isList declaration
        then declaration
        else if lib.isAttrs declaration && declaration ? command
        then lib.toList declaration.command
        else null;
      command =
        if commandValues == null
        then null
        else map toString commandValues;
      position = builtins.unsafeGetAttrPos "updateScript" (package.passthru or {});
      ours =
        command
        != null
        && command != []
        && position != null
        && lib.hasPrefix srcRoot position.file;
      value = lib.optionalAttrs ours {
        ${address} =
          {
            inherit command;
            commandDrvPaths = commandDrvsOf commandValues;
            version = package.version or null;
            position = package.meta.position or null;
            ownership = updateOwnership package;
          }
          // lib.optionalAttrs (lib.isAttrs declaration && declaration ? name) {inherit (declaration) name;}
          // lib.optionalAttrs (lib.isAttrs declaration && declaration ? attrPath) {inherit (declaration) attrPath;}
          // lib.optionalAttrs (lib.isAttrs declaration && declaration ? accepts) {inherit (declaration) accepts;}
          // lib.optionalAttrs (lib.isAttrs declaration && declaration ? source) {inherit (declaration) source;};
      };
      result = builtins.tryEval (builtins.deepSeq value value);
    in
      if result.success
      then result.value
      else {};
  in
    lib.concatMapAttrs scriptFor updateCandidates;
  updateNotes = let
    noted = lib.filterAttrs (_: wasinixLib.hasUpdateNotes) updateCandidates;
    versionOf = package: let
      attempted = builtins.tryEval (wasinixLib.noteVersionOf package);
    in
      if attempted.success
      then attempted.value
      else null;
  in {
    versions = lib.mapAttrs (_: versionOf) noted;
    fired = priors:
      lib.filterAttrs (_: notes: notes != [])
      (lib.mapAttrs (address: wasinixLib.firedNotesOf (priors.${address} or null)) noted);
  };
  postUpdateHooks = let
    srcRoot = toString root;
    hookFor = address: package: let
      declaration = (package.passthru.wasinix.update or {}).post or null;
      syncAttrList =
        if lib.isAttrs declaration
        then declaration.syncAttrList or null
        else null;
      commandValues =
        if declaration == null || syncAttrList != null
        then null
        else lib.toList declaration;
      action =
        if syncAttrList != null
        then syncAttrList // {kind = "syncAttrList";}
        else if commandValues != null
        then {
          kind = "command";
          command = map toString commandValues;
          commandDrvPaths = commandDrvsOf commandValues;
        }
        else null;
      position = builtins.unsafeGetAttrPos "wasinix" (package.passthru or {});
      ours =
        action
        != null
        && position != null
        && lib.hasPrefix srcRoot position.file;
      value = lib.optionalAttrs ours {
        ${address} = {
          inherit action;
          version = package.version or null;
        };
      };
      result = builtins.tryEval (builtins.deepSeq value value);
    in
      if result.success
      then result.value
      else {};
  in
    lib.concatMapAttrs hookFor updateCandidates;
  currentOwnedEntries = entriesMatching (entry: entry.instance.kind == "current");
  servedValue = history_spec: entry: {
    version = toString entry.instance.version;
    inherit history_spec;
    retention = entry.policy.retention or null;
  };
  uniqueServed = kind: historySpec: entries: let
    values = lib.unique (map (servedValue historySpec) entries);
  in
    lib.throwIf (lib.length values != 1)
    "current ${kind} entries disagree on served-version metadata"
    (builtins.head values);
  wheelEntries = lib.filter (entry:
    entry.kind
    == "artifact"
    && lib.hasPrefix "wheel-" entry.artifactKind)
  currentOwnedEntries;
  cliEntries = lib.filter (entry:
    entry.kind
    == "package"
    && entry.scope == "wasix"
    && entry.preferred
    && (entry.policy.shipped or false))
  currentOwnedEntries;
  servedVersions = {
    wheel = lib.mapAttrs (name: entries:
      uniqueServed "wheel ${name}" "packages.python.${name}" entries)
    (lib.groupBy (entry: entry.name) wheelEntries);
    cli = lib.mapAttrs (name: entries:
      uniqueServed "CLI ${name}" "packages.wasix.${name}" entries)
    (lib.groupBy (entry: entry.name) cliEntries);
  };
  noteVersions = builtins.tryEval updateNotes.versions;
  updateSnapshot = {
    schemaVersion = 1;
    inherit postUpdateHooks servedVersions updateScripts;
    notes = {
      ok = noteVersions.success;
      value =
        if noteVersions.success
        then noteVersions.value
        else {};
    };
  };
in {
  inherit root source;
  revisions = builtins.fromJSON (builtins.readFile revisionsFile);
  publication = {
    catalog =
      lib.mapAttrs (_: info: {
        inherit (info) identity kind packageSubjects;
      })
      publicationInfo;
    destinations = publication;
    info = publicationInfo;
    versions = lib.mapAttrs (_: info: info.versions) publicationInfo;
  };
  updates = {
    inherit postUpdateHooks updateNotes updateScripts;
    snapshot = updateSnapshot;
  };
}
