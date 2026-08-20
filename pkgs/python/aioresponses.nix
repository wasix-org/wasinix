# aioresponses imports packaging at runtime; nixpkgs doesn't propagate it
# (its native test env happens to provide it). overridePythonAttrs, not
# extendPackage cannot change requiredPythonModules computed by the builder.
{
  pyfinal,
  pyprev,
  ...
}:
pyprev.aioresponses.overridePythonAttrs (o: {
  propagatedBuildInputs = (o.propagatedBuildInputs or []) ++ [pyfinal.packaging];
})
