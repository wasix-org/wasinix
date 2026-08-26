{
  lib,
  makeWasmerPackage,
  webcIdent,
}: let
  commandsForPackage = {
    artifact,
    label,
    package,
  }: let
    manifest = package.passthru.wasmer or {};
    identity = webcIdent package;
    version = lib.optionalString (manifest.history or false) identity.baseVersion;
    declaredCommands = manifest.commands or null;
    commandSpecs =
      if declaredCommands == null
      then [
        {
          inherit (identity) name;
          entrypoint = manifest.entrypoint or identity.name;
          global = true;
        }
      ]
      else if builtins.isList declaredCommands
      then
        map (command: {
          name =
            if lib.isAttrs command
            then command.name or null
            else null;
          entrypoint =
            if lib.isAttrs command
            then command.name or null
            else null;
          global =
            if lib.isAttrs command
            then command.global or (!(command ? dependency))
            else true;
        })
        declaredCommands
      else [];
    invalidCommands = lib.filter (command:
      !builtins.isString command.name
      || !builtins.isString command.entrypoint)
    commandSpecs;
    duplicateCommands = lib.attrNames (lib.filterAttrs (_: commands: lib.length commands > 1) (lib.groupBy (command: command.name) commandSpecs));
  in
    lib.throwIf (declaredCommands != null && !builtins.isList declaredCommands)
    "${label}: passthru.wasmer.commands must be a list or null"
    (lib.throwIf (invalidCommands != [])
      "${label}: passthru.wasmer.commands contains a command without a string name"
      (lib.throwIf (duplicateCommands != [])
        "${label}: passthru.wasmer.commands contains duplicate name(s): ${lib.concatStringsSep ", " duplicateCommands}"
        (lib.listToAttrs (map (command:
          lib.nameValuePair command.name {
            inherit artifact package version;
            inherit (command) name entrypoint global;
          })
        commandSpecs))));
in {
  inherit commandsForPackage;

  wasmerArtifacts = {
    entry,
    packages,
    ...
  }:
    lib.optionalAttrs (
      entry.kind
      == "package"
      && entry.scope == "wasix"
      && entry.preferred
      && entry.policy.shipped or false
      && !(entry.package.meta.broken or false)
    ) (let
      current = packages.sameProfile.${entry.name};
      servedVersions = lib.unique (map (package: (webcIdent package).baseVersion) ([current] ++ lib.attrValues current.versions));
      package = makeWasmerPackage {
        inherit (entry) package;
        inherit servedVersions;
      };
    in {
      artifacts = {
        pkg = package;
        inherit (package) webc;
      };
    });

  wasmerCommands = {
    entry,
    packages,
    ...
  }:
    lib.optionalAttrs (entry.kind == "artifact" && entry.artifactKind == "webc") (let
      current = packages.sameProfile.${entry.name};
      subjectPackage =
        if entry.instance.kind == "history"
        then current.versions.${entry.instance.version}
        else current;
      commands = commandsForPackage {
        inherit (entry) artifact;
        label = entry.address;
        package = subjectPackage;
      };
    in {inherit commands;});
}
