# The wheel declares semantic-conventions as a runtime dependency, but nixpkgs'
# split package omits it from the propagated closure.
{
  helpers,
  pyfinal,
  pyprev,
  ...
}:
helpers.extendPackage pyprev.opentelemetry-instrumentation {
  propagatedBuildInputs = [pyfinal.opentelemetry-semantic-conventions];
}
