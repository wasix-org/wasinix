# aioresponses imports packaging at runtime; nixpkgs doesn't propagate it
# (its native test env happens to provide it). overridePythonAttrs, not
# libTweaks: requiredPythonModules is computed from the builder arguments.
{
  pyfinal,
  pyprev,
  ...
}:
pyprev.aioresponses.overridePythonAttrs (o: {
  propagatedBuildInputs = (o.propagatedBuildInputs or []) ++ [pyfinal.packaging];
})
