# envier for wasix (not in nixpkgs): DataDog's env-var configuration library,
# pure python; ddtrace's runtime dep. No suite: the sdist ships no tests.
{
  pyfinal,
  nix-update-script,
  ...
}:
pyfinal.buildPythonPackage (finalAttrs: {
  pname = "envier";
  version = "0.6.1";
  pyproject = true;

  src = pyfinal.fetchPypi {
    inherit (finalAttrs) pname version;
    hash = "sha256-MwmgG7PYhQyeejGlFm1ag2hG2y+uy3m5yzJlTdUMqfk=";
  };

  build-system = [
    pyfinal.hatchling
    pyfinal.hatch-vcs
  ];

  passthru.updateScript = nix-update-script {extraArgs = ["--flake"];};
})
