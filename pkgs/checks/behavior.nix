{
  lib,
  projectLib,
}: {
  packageBehavior = {
    artifacts,
    commands,
    entry,
    harnesses,
    packageForEntry,
    packages,
    pkgs,
    runners,
    ...
  }:
    lib.optionalAttrs (
      entry.kind
      == "package"
      && (
        (entry.policy.checks.behavior or false)
        || (entry.scope == "wasix" && !(entry.policy.shipped or false))
      )
      && entry.definition != null
      && entry.definition.directory != null
      && builtins.pathExists (entry.definition.directory + "/tests")
    ) (let
      testEntry =
        if entry.commands != {}
        then entry
        else
          entry
          // {
            commands = harnesses.packageCommands (packageForEntry packages entry);
          };
    in {
      tests = projectLib.loadTestDirectory {
        dir = entry.definition.directory + "/tests";
        context = {
          inherit artifacts commands harnesses packageForEntry packages pkgs runners;
          entry = testEntry;
        };
      };
    });

  packagedBehavior = {
    artifacts,
    commands,
    entry,
    harnesses,
    packageForEntry,
    packages,
    pkgs,
    runners,
    ...
  }:
    lib.optionalAttrs (
      entry.kind
      == "artifact"
      && entry.artifactKind == "webc"
      && entry.definition != null
      && entry.definition.directory != null
      && builtins.pathExists (entry.definition.directory + "/tests")
    ) {
      tests = projectLib.loadTestDirectory {
        dir = entry.definition.directory + "/tests";
        context = {
          inherit artifacts commands entry harnesses packageForEntry packages pkgs runners;
        };
      };
    };
}
