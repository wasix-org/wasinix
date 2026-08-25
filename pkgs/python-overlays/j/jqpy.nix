# jqpy for wasix (not in nixpkgs): a thin wrapper that spawns the `jq` binary
# found via shutil.which. Upstream's contract is "jq must be installed and on
# PATH", so we keep that (no baked /nix/store path -> the wheel stays
# relocatable for pip); a consumer provides jq (the webc mounts the jq command,
# a pip user installs it). Import does not spawn jq, so it works standalone.
# No suite: the released sdist ships no tests.
{
  exposePackage,
  packages,
  pkgs,
}:
exposePackage (
  packages.sameProfile.buildPythonPackage (finalAttrs: {
    pname = "jqpy";
    version = "1.0.0";
    pyproject = true;

    src = packages.sameProfile.fetchPypi {
      inherit (finalAttrs) pname version;
      hash = "sha256-Cnhpuu3AgeEJnzhyeqfnbZJk+XLeZcdmGztnyCHQMh0=";
    };

    build-system = [packages.sameProfile.flit-core];

    passthru.updateScript = pkgs.buildPackages.nix-update-script {extraArgs = ["--flake"];};
  })
)
