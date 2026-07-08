# jqpy for wasix (not in nixpkgs): a thin wrapper that spawns the `jq` binary
# found via shutil.which. Upstream's contract is "jq must be installed and on
# PATH", so we keep that (no baked /nix/store path -> the wheel stays
# relocatable for pip); a consumer provides jq (the webc mounts the jq command,
# a pip user installs it). Import does not spawn jq, so it works standalone.
{pyfinal, ...}:
pyfinal.buildPythonPackage rec {
  pname = "jqpy";
  version = "1.0.0";
  pyproject = true;

  src = pyfinal.fetchPypi {
    inherit pname version;
    hash = "sha256-Cnhpuu3AgeEJnzhyeqfnbZJk+XLeZcdmGztnyCHQMh0=";
  };

  build-system = [pyfinal.flit-core];
}
