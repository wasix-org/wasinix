# envier for wasix (not in nixpkgs): DataDog's env-var configuration library,
# pure python; ddtrace's runtime dep.
{pyfinal, ...}:
pyfinal.buildPythonPackage rec {
  pname = "envier";
  version = "0.6.1";
  pyproject = true;

  src = pyfinal.fetchPypi {
    inherit pname version;
    hash = "sha256-MwmgG7PYhQyeejGlFm1ag2hG2y+uy3m5yzJlTdUMqfk=";
  };

  build-system = [
    pyfinal.hatchling
    pyfinal.hatch-vcs
  ];
}
