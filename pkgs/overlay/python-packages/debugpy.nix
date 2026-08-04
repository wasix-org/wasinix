# debugpy for wasix. Its preBuild compiles the pydevd attach-to-process helper,
# which injects into a target process via ptrace/dlopen; wasm has neither, and
# skipping it costs only attach-to-running-process.
{
  pyprev,
  helpers,
  ...
}:
helpers.libTweaks {preBuild = _: "";}
pyprev.debugpy
