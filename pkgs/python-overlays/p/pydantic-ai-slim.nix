# pydantic-ai-slim pins pydantic-graph to its own release, which the set no
# longer ships, so a rebased version takes the matching history entry.
{
  exposeExtendedPackage,
  packages,
  package,
  lib,
  replaceInputsByName,
}:
exposeExtendedPackage (lib.optionalAttrs ((package.passthru.wasix.historySpec or null) != null) {
  propagatedBuildInputs = replaceInputsByName {
    pydantic-graph = packages.sameProfile.pydantic-graph.versions.${package.version};
  };
})
