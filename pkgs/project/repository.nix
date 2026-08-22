{
  lib,
  project,
  revisionsFile,
  root,
  source,
}: let
  wasinixLib = import ../lib {inherit lib;};
  registry = project.artifacts.registry.python;
  cargoRegistryArtifact = project.artifacts.registry.cargo-registry;

  firstChangelog = derivations:
    lib.findFirst (value: value != null) null
    (map (derivation: let
      attempted = builtins.tryEval (derivation.meta.changelog or null);
    in
      if attempted.success
      then attempted.value
      else null)
    derivations);
  informationFor = {
    kind,
    versionOf,
    changelogOf ? (derivation: derivation),
    derivations,
  }: {
    versions = lib.unique (map versionOf derivations);
    inherit kind;
    changelogs =
      lib.mapAttrs (_: values: firstChangelog (map changelogOf values))
      (lib.groupBy versionOf derivations);
    derivations = lib.mapAttrs (_: values:
      map (derivation: builtins.unsafeDiscardStringContext derivation.drvPath) values)
    (lib.groupBy versionOf derivations);
  };
  wheelDerivations = name:
    lib.concatMap (perInterpreter: lib.attrValues (perInterpreter.${name} or {}))
    (lib.attrValues registry.wheels);
  wheelInfo = lib.mapAttrs' (name: _:
    lib.nameValuePair "artifacts.registry.python.wheels.${name}" (informationFor {
      kind = "wheel";
      versionOf = derivation: derivation.version;
      derivations = wheelDerivations name;
    }))
  registry.wheelVersions;
  webcInfo = lib.mapAttrs' (name: package:
    lib.nameValuePair "artifacts.webc.${name}" (informationFor {
      kind = "webc";
      versionOf = derivation: derivation.id.baseVersion;
      derivations = [package] ++ builtins.attrValues (package.versions or {});
    }))
  project.artifacts.pkg;
  cargoInfo = lib.mapAttrs' (name: _:
    lib.nameValuePair "artifacts.registry.cargo-registry.crates.${name}" (informationFor {
      kind = "crate";
      versionOf = derivation: derivation.passthru.version;
      derivations = builtins.attrValues (cargoRegistryArtifact.crates.${name} or {});
    }))
  cargoRegistryArtifact.crateVersions;
  publicationInfo = wheelInfo // webcInfo // cargoInfo;

  packagesFrom = prefix: packages:
    lib.mapAttrs' (name: package: lib.nameValuePair "${prefix}.${name}" package)
    (lib.filterAttrs (_: package: (package.passthru.wasinix.source or null) == source) packages);
  updateCandidates =
    packagesFrom "packages.native" project.packages.native
    // packagesFrom "packages.wasix" project.packages.preferred
    // lib.optionalAttrs (project.packages.python ? preferred)
    (packagesFrom "packages.python.preferred" project.packages.python.preferred);
  commandDrvsOf = lib.concatMap (value:
    if lib.isDerivation value
    then [value.drvPath]
    else builtins.attrNames (builtins.getContext (toString value)));
  updateScripts = let
    srcRoot = toString root;
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
      command =
        if declaration == null
        then null
        else map toString (lib.toList declaration);
      position = builtins.unsafeGetAttrPos "wasinix" (package.passthru or {});
      ours =
        command
        != null
        && command != []
        && position != null
        && lib.hasPrefix srcRoot position.file;
      value = lib.optionalAttrs ours {
        ${address} = {
          inherit command;
          commandDrvPaths = commandDrvsOf (lib.toList declaration);
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
in {
  inherit root source;
  revisions = builtins.fromJSON (builtins.readFile revisionsFile);
  publication = {
    info = publicationInfo;
    versions = lib.mapAttrs (_: info: info.versions) publicationInfo;
  };
  updates = {
    inherit postUpdateHooks updateNotes updateScripts;
  };
}
