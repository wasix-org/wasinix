# Static PEP 503 "simple" index over the shipped wheels (pkgs/python-wheels.nix), MERGED across
# python versions: each wheel carries its cp313/cp314 tag in the filename, so one index serves both
# and a resolver picks the file matching the running interpreter.
#
#   nix build .#pythonRegistry
#   pip install --index-url file://$(readlink -f result)/simple numpy
{
  pkgs,
  lib,
  # {py313 = {python3; pythonWheels; omitFromRegistry ? [];}; py314 = {...};}:
  # one closure + wheel set per version. omitFromRegistry removes only the named
  # artifacts after computing the closure, so their version-specific deps remain.
  pythonSets,
  testLib,
  # the default python interpreter + its webc (both from the top-level `python3`). The e2e installs
  # from the merged index, targeting this version's tags, and runs on the webc.
  python3,
  pythonWebc,
  mkTestGroup,
}: let
  # Publication release numbers (PEP 440 local version +wasix.N), from the global rels.json at the
  # repo root: keyed by attr path (pythonRegistry.wheels.<pname>) then upstream version, so an
  # upstream bump resets to 1 by key miss. Shared across python versions (same upstream version),
  # the cp tag keeps filenames distinct. Bump when republishing a changed build; published
  # filenames are immutable, so publish.py retains the original artifact on name reuse.
  rels = builtins.fromJSON (builtins.readFile ../../rels.json);
  relPrefix = "pythonRegistry.wheels.";

  # Repo-relative "path:line" of the package definition, for the index's
  # publish-time source link. Only for positions in this repo: closure wheels
  # defined in nixpkgs would produce dead links.
  repoRoot = toString ../.. + "/";
  sourceOf = drv: let
    pos = drv.meta.position or null;
    m =
      if pos == null
      then null
      else builtins.match "(.*):([0-9]+)" pos;
  in
    if m != null && lib.hasPrefix repoRoot (builtins.head m)
    then "${lib.removePrefix repoRoot (builtins.head m)}:${builtins.elemAt m 1}"
    else null;

  # Per-version served wheels (full runtime closure, not just the worklist). buildPythonPackage puts
  # the .whl in `dist`; toPythonModule-wrapped non-python drvs have none and can't be served.
  servedOf = pv: set: let
    closure = set.python3.pkgs.requiredPythonModules (lib.attrValues set.pythonWheels);
  in
    map (drv: rec {
      name = drv.pname or drv.name;
      version = drv.version;
      relKey = "${relPrefix}${name}";
      rel = (rels."${relPrefix}${name}" or {}).${version} or 1;
      dist = "${drv.dist}";
      # provenance nested by python version and upstream version, so pname collides neither
      # across py313/py314 nor with a served history version of itself:
      # `nix build github:wasix-org/wasinix/<rev>#${attr}` rebuilds it.
      attr = ''pythonRegistry.wheels.${pv}.${name}."${version}"^dist'';
      drvPath = builtins.unsafeDiscardStringContext drv.drvPath;
      source = sourceOf drv;
      inherit drv;
    })
    (lib.filter
      (drv: drv ? dist && !(lib.elem (drv.pname or drv.name) (set.omitFromRegistry or [])))
      closure);

  perVersion = lib.mapAttrs servedOf pythonSets;
  wheelDists = lib.concatLists (lib.attrValues perVersion);

  # Provenance build targets (pythonRegistry.wheels.py314.numpy."2.5.0").
  wheels =
    lib.mapAttrs (
      _: served:
        lib.mapAttrs (_: ds: lib.listToAttrs (map (d: lib.nameValuePair d.version d.drv) ds))
        (lib.groupBy (d: d.name) served)
    )
    perVersion;

  # name -> served upstream versions (current + history; same across py versions); read by
  # the update driver to prune rels.json.
  wheelVersions = lib.mapAttrs (_: ds: lib.unique (map (d: d.version) ds)) (lib.groupBy (d: d.name) wheelDists);
  # rels.json keys no served wheel carries: left behind by an upstream bump, or a dropped
  # history entry. The update driver drops them (regen hook on nixpkgs), this note covers bumps
  # made by hand. Only this registry's key prefix; webc keys get the same note per package.
  staleRels = lib.concatMap (
    key: let
      name = lib.removePrefix relPrefix key;
    in
      lib.optionals (lib.hasPrefix relPrefix key)
      (map (v: "${key} ${v}")
        (lib.filter (v: !(lib.elem v (wheelVersions.${name} or [])))
          (lib.attrNames rels.${key})))
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
          message = "rels.json has stale keys (${lib.concatStringsSep ", " staleRels}); nix run .#update -- nixpkgs drops them";
          when = _: _: true;
        };
      };
  })
