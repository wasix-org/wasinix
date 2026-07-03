# Static PEP 503 "simple" index over the shipped wheels (pkgs/python-wheels.nix):
#
#   nix build .#pythonRegistry
#   pip install --index-url file://$(readlink -f result)/simple numpy
{
  pkgs,
  lib,
  # eval-only (closure, version tags); the tests run the shipped python webc.
  python3,
  pythonWheels,
  testLib,
  pythonWebc,
  mkTestGroup,
}: let
  # Full runtime closure, not just the wheels.nix worklist: resolving any listed
  # package needs its transitive deps present as wheels too. Already unique.
  closure = python3.pkgs.requiredPythonModules (lib.attrValues pythonWheels);

  # buildPythonPackage puts the built .whl in the `dist` output;
  # toPythonModule-wrapped non-python drvs have none and can't be served.
  wheelDists = map (drv: {
    name = drv.pname or drv.name;
    dist = "${drv.dist}";
  }) (lib.filter (drv: drv ? dist) closure);
  registry =
    pkgs.runCommand "wasix-python-registry" {
      nativeBuildInputs = [pkgs.python3];
      distsJson = builtins.toJSON wheelDists;
      passAsFile = ["distsJson"];
    } ''
      python3 ${./make-index.py} "$distsJsonPath" "$out"
    '';

  tests = import ./tests.nix {inherit pkgs lib registry python3 testLib pythonWebc;};
in
  registry.overrideAttrs (o: {
    passthru = (o.passthru or {}) // {tests = mkTestGroup "python-registry" tests;};
  })
