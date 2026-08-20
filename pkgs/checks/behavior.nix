{
  lib,
  projectLib,
}: {
  packagedBehavior = {
    artifacts,
    commands,
    entry,
    harnesses,
    packages,
    pkgs,
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
          inherit artifacts commands entry harnesses packages pkgs;
        };
      };
    };
}
