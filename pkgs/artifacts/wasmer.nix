{
  lib,
  makeWasmerPackage,
  webcIdent,
}: {
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
      && (entry.policy.shipped or false)
      && !(entry.package.meta.broken or false)
    ) (let
      current = packages.sameProfile.${entry.name};
      servedVersions = lib.unique (map (package: (webcIdent package).baseVersion) ([current] ++ lib.attrValues current.versions));
      package = makeWasmerPackage {
        package = entry.package;
        inherit servedVersions;
      };
    in {
      artifacts = {
        pkg = package;
        webc = package.webc;
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
      manifest = subjectPackage.passthru.wasmer or {};
      identity = webcIdent subjectPackage;
      declaredCommands = manifest.commands or null;
      commandSpecs =
        if declaredCommands == null
        then [
          {
            name = identity.name;
            entrypoint = manifest.entrypoint or identity.name;
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
          })
          declaredCommands
        else [];
      invalidCommands = lib.filter (command:
        !builtins.isString command.name
        || !builtins.isString command.entrypoint)
      commandSpecs;
      duplicateCommands = lib.attrNames (lib.filterAttrs (_: commands: lib.length commands > 1) (lib.groupBy (command: command.name) commandSpecs));
      commands = lib.listToAttrs (map (command:
        lib.nameValuePair command.name {
          inherit (command) name entrypoint;
          artifact = entry.artifact;
        })
      commandSpecs);
    in
      lib.throwIf (declaredCommands != null && !builtins.isList declaredCommands)
      "${entry.address}: passthru.wasmer.commands must be a list or null"
      (lib.throwIf (invalidCommands != [])
        "${entry.address}: passthru.wasmer.commands contains a command without a string name"
        (lib.throwIf (duplicateCommands != [])
          "${entry.address}: passthru.wasmer.commands contains duplicate name(s): ${lib.concatStringsSep ", " duplicateCommands}"
          {inherit commands;})));
}
