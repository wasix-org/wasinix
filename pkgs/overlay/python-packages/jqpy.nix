# jqpy for wasix (not in nixpkgs): a thin wrapper that spawns the `jq` binary
# found via shutil.which. Upstream's contract is "jq must be installed and on
# PATH", so we keep that (no baked /nix/store path -> the wheel stays
# relocatable for pip); a consumer provides jq (the webc mounts the jq command,
# a pip user installs it). Import does not spawn jq, so it works standalone.
# No suite: the released sdist ships no tests.
{
  pyfinal,
  nix-update-script,
  ...
}:
pyfinal.buildPythonPackage (finalAttrs: {
  pname = "jqpy";
  version = "1.0.0";
  pyproject = true;

  src = pyfinal.fetchPypi {
    inherit (finalAttrs) pname version;
    hash = "sha256-Cnhpuu3AgeEJnzhyeqfnbZJk+XLeZcdmGztnyCHQMh0=";
  };

  build-system = [pyfinal.flit-core];

  passthru.updateScript = nix-update-script {extraArgs = ["--flake"];};
})
