# pydantic-ai-slim pins pydantic-graph to its own release, which the set no
# longer ships, so a rebased version takes the matching history entry.
{
  pyprev,
  pyfinal,
  helpers,
  lib,
  ...
}:
helpers.libTweaks (lib.optionalAttrs ((pyprev.pydantic-ai-slim.passthru.wasix.historySpec or null) != null) {
  propagatedBuildInputs = helpers.replaceInputsByName {
    pydantic-graph = pyfinal."pydantic-graph_${lib.replaceStrings ["."] ["_"] pyprev.pydantic-ai-slim.version}";
  };
})
pyprev.pydantic-ai-slim
