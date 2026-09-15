# PyPI ships 4.9.3 as an sdist only, so under --only-binary the registry must
# serve our pure build or omegaconf and hydra-core (which pin ==4.9.*) cannot
# resolve.
{exposeExtendedPackage}:
exposeExtendedPackage {
  passthru.wasinix.publication.supersedesPyPI = true;
}
