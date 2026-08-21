# This package is a test dependency whose pytest hook cannot run while the
# cross package is being built without a Wasmer runtime.
{
  exposePackage,
  package,
}:
exposePackage (
  package.overridePythonAttrs (_: {dontUsePytestCheck = true;})
)
