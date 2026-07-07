# jqpy for wasix (not in nixpkgs): a pure wrapper that spawns the jq binary
# via shutil.which; point it at the wasix jq CLI instead (subprocess works
# via posix_spawn, and the smoke-test store mount makes the path loadable).
{
  pyfinal,
  preferredProfilePackages,
  ...
}:
pyfinal.buildPythonPackage rec {
  pname = "jqpy";
  version = "1.0.0";
  pyproject = true;

  src = pyfinal.fetchPypi {
    inherit pname version;
    hash = "sha256-Cnhpuu3AgeEJnzhyeqfnbZJk+XLeZcdmGztnyCHQMh0=";
  };

  build-system = [pyfinal.flit-core];

  postPatch = ''
    substituteInPlace jqpy.py \
      --replace-fail "shutil.which('jq')" '"${preferredProfilePackages.jq}/bin/jq.wasm"'
  '';
}
