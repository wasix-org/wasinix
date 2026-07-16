# Static PEP 503 "simple" index over the shipped wheels (pkgs/python-wheels.nix), MERGED across
# python versions: each wheel carries its cp313/cp314 tag in the filename, so one index serves both
# and a resolver picks the file matching the running interpreter.
#
#   nix build .#pythonRegistry
#   pip install --index-url file://$(readlink -f result)/simple numpy
{
  pkgs,
  lib,
  # {py313 = {python3; pythonWheels;}; py314 = {...};}: one closure + wheel set per version.
  pythonSets,
  testLib,
  # the default python interpreter + its webc (both from the top-level `python3`). The e2e installs
  # from the merged index, targeting this version's tags, and runs on the webc.
  python3,
  pythonWebc,
  mkTestGroup,
}: let
  # Publication release numbers (PEP 440 local version +wasix.N): keyed by pname then upstream
  # version. Shared across python versions (same upstream version), the cp tag keeps filenames
  # distinct. Bump when republishing a changed build; published filenames are immutable.
  rels = builtins.fromJSON (builtins.readFile ./rels.json);

  # Per-version served wheels (full runtime closure, not just the worklist). buildPythonPackage puts
  # the .whl in `dist`; toPythonModule-wrapped non-python drvs have none and can't be served.
  servedOf = pv: set: let
    closure = set.python3.pkgs.requiredPythonModules (lib.attrValues set.pythonWheels);
  in
    map (drv: rec {
      name = drv.pname or drv.name;
      version = drv.version;
      rel = (rels.${name} or {}).${version} or 1;
      dist = "${drv.dist}";
      # provenance nested by version so pname doesn't collide across py313/py314:
      # `nix build github:wasix-org/wasinix/<rev>#${attr}` rebuilds it.
      attr = "pythonRegistry.wheels.${pv}.${name}^dist";
      drvPath = builtins.unsafeDiscardStringContext drv.drvPath;
      inherit drv;
    })
    (lib.filter (drv: drv ? dist) closure);

  perVersion = lib.mapAttrs servedOf pythonSets;
  wheelDists = lib.concatLists (lib.attrValues perVersion);

  # Provenance build targets, nested by version (pythonRegistry.wheels.py314.numpy).
  wheels = lib.mapAttrs (_: served: lib.listToAttrs (map (d: lib.nameValuePair d.name d.drv) served)) perVersion;

  # name -> upstream version (same across py versions); read by scripts/update.py to prune rels.json.
  wheelVersions = lib.listToAttrs (map (d: lib.nameValuePair d.name d.version) wheelDists);
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

  # e2e/import tests run on the default python webc, installing from the merged index.
  tests = import ./tests.nix {
    inherit pkgs lib registry testLib pythonWebc python3;
  };
in
  registry.overrideAttrs (o: {
    passthru =
      (o.passthru or {})
      // {
        tests = mkTestGroup "python-registry" tests;
        inherit wheelVersions wheels;
        wasix.updateNotes = lib.optional (staleRels != []) {
          message = "rels.json has stale keys (${lib.concatStringsSep ", " staleRels}); nix run .#scripts.update -- --only nixpkgs drops them";
          when = _: _: true;
        };
      };
  })
