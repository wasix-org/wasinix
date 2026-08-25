# aioresponses imports packaging at runtime; nixpkgs doesn't propagate it
# (its native test env happens to provide it). overridePythonAttrs, not
# extendPackage cannot change requiredPythonModules computed by the builder.
{
  exposePackage,
  packages,
  package,
}:
exposePackage (
  package.overridePythonAttrs (o: {
    propagatedBuildInputs = (o.propagatedBuildInputs or []) ++ [packages.sameProfile.packaging];
  })
)
