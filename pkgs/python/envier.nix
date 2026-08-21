# envier for wasix (not in nixpkgs): DataDog's env-var configuration library,
# pure python; ddtrace's runtime dep. No suite: the sdist ships no tests.
{
  exposePackage,
  packages,
  pkgs,
}:
exposePackage (
  packages.sameProfile.buildPythonPackage rec {
    pname = "envier";
    version = "0.6.1";
    pyproject = true;

    src = packages.sameProfile.fetchPypi {
      inherit pname version;
      hash = "sha256-MwmgG7PYhQyeejGlFm1ag2hG2y+uy3m5yzJlTdUMqfk=";
    };

    build-system = [
      packages.sameProfile.hatchling
      packages.sameProfile.hatch-vcs
    ];

    passthru.updateScript = pkgs.buildPackages.nix-update-script {extraArgs = ["--flake"];};
  }
)
