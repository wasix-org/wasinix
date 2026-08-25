# The wheel declares semantic-conventions as a runtime dependency, but nixpkgs'
# split package omits it from the propagated closure.
{
  exposeExtendedPackage,
  packages,
}:
exposeExtendedPackage {
  propagatedBuildInputs = [packages.sameProfile.opentelemetry-semantic-conventions];
}
