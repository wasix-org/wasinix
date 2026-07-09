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

  # Publication release numbers (PEP 440 local version +wasix.N): keyed by
  # pname then upstream version, so an upstream bump resets to 1 by key miss.
  # Bump when republishing a changed build of the same upstream version;
  # published wheel filenames are immutable, publish.py refuses reuse.
  rels = builtins.fromJSON (builtins.readFile ./rels.json);

  # buildPythonPackage puts the built .whl in the `dist` output;
  # toPythonModule-wrapped non-python drvs have none and can't be served.
  wheelDists = map (drv: rec {
    name = drv.pname or drv.name;
    version = drv.version;
    rel = (rels.${name} or {}).${version} or 1;
    dist = "${drv.dist}";
  }) (lib.filter (drv: drv ? dist) closure);

  wheelVersions = lib.listToAttrs (map (d: lib.nameValuePair d.name d.version) wheelDists);
  # rels.json keys left behind by an upstream bump; scripts/update.py drops
  # them (regen hook on nixpkgs), this note covers bumps made by hand.
  staleRels = lib.concatMap (
    name:
      map (v: "${name} ${v}")
      (lib.filter (v: (wheelVersions.${name} or null) != v)
        (lib.attrNames rels.${name}))
  ) (lib.attrNames rels);
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
    passthru =
      (o.passthru or {})
      // {
        tests = mkTestGroup "python-registry" tests;
        # read by scripts/update.py to prune rels.json after a nixpkgs bump
        inherit wheelVersions;
        wasix.updateNotes = lib.optional (staleRels != []) {
          message = "rels.json has stale keys (${lib.concatStringsSep ", " staleRels}); nix run .#update -- --only nixpkgs drops them";
          when = _: _: true;
        };
      };
  })
