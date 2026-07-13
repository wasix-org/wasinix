# sse-starlette for wasix. Its wheel Requires-Dist lists starlette, but nixpkgs
# marks starlette an optional dependency, so an isolated cross build lacks it and
# the runtime-deps check flags it absent. Consumers (mcp, claude-agent-sdk) pull
# starlette themselves; skip the check here.
{pyprev, ...}:
pyprev.sse-starlette.overridePythonAttrs (_: {
  dontCheckRuntimeDeps = true;
})
