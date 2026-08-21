# Static PEP 503 "simple" index over the shipped wheels (pkgs/python-wheels.nix), MERGED across
# python versions: each wheel carries its cp313/cp314 tag in the filename, so one index serves both
# and a resolver picks the file matching the running interpreter.
#
#   nix build .#pythonRegistry
#   pip install --index-url file://$(readlink -f result)/all/simple numpy
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
  # The wheels carry their own release (pkgs/python-publish.nix). Revision
  # state is read only to report keys no served version claims.
  rels = builtins.fromJSON (builtins.readFile ../../release-revisions.json);
  relPrefix = "artifacts.registry.python314.wheels.";
  inherit (import ../python-publish.nix {inherit pkgs lib;}) publishOf interpreters;

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
      # the publishable form, produced by the wheel's own derivation. A package
      # whose build follows the interpreter is published per set instead, under
      # a tag naming it, since one none-any filename cannot hold both builds.
      publishedDrv =
        if drv.passthru.wasix.interpreterSpecific or false
        then
          publishOf {
            inherit drv;
            pythonTag = "cp${lib.removePrefix "py" pv}";
          }
        else drv.published or (publishOf {inherit drv;});
      published = "${publishedDrv}";
      # provenance nested by python version and upstream version, so pname collides neither
      # across py313/py314 nor with a served history version of itself:
      # `nix build github:wasix-org/wasinix/<rev>#legacyPackages.x86_64-linux.${attr}`
      # rebuilds it.
      attr = ''artifacts.registry.python314.published.${pv}.${name}."${version}"'';
      drvPath = builtins.unsafeDiscardStringContext drv.drvPath;
      source = sourceOf drv;
      # our build differs from upstream's, so PyPI cannot stand in for it
      supersedes = drv.passthru.wasix.supersedesPyPI or false;
      inherit drv;
    })
    (lib.filter
      (drv: drv ? dist && !(lib.elem (drv.pname or drv.name) (set.omitFromRegistry or [])))
      closure);

  perVersion = lib.mapAttrs servedOf pythonSets;

  # pname -> the interpreter versions a resolver can reach it on. A wheel set is
  # built per interpreter, so carrying the project is what makes it visible
  # there; a noarch wheel sits in one set alone and is swept on that one.
  projectInterpreters = lib.foldl' (
    acc: pv:
      lib.foldl' (a: e:
        a // {${e.name} = lib.unique ((a.${e.name} or []) ++ [interpreters.${pv}]);})
      acc
      perVersion.${pv}
  ) {} (lib.attrNames perVersion);
  wheelDists = lib.concatLists (lib.attrValues perVersion);

  # The published artifacts, addressable so the reproduce command on an index
  # page names the bytes it describes (pythonRegistry.published.py314.numpy."2.5.0").
  published =
    lib.mapAttrs (
      _: served:
        lib.mapAttrs (_: ds: lib.listToAttrs (map (d: lib.nameValuePair d.version d.publishedDrv) ds))
        (lib.groupBy (d: d.name) served)
    )
    perVersion;

  # The source wheels behind them; the rel and changelog machinery reads these
  # (flake.nix), so they stay the buildPythonPackage drvs.
  wheels =
    lib.mapAttrs (
      _: served:
        lib.mapAttrs (_: ds: lib.listToAttrs (map (d: lib.nameValuePair d.version d.drv) ds))
        (lib.groupBy (d: d.name) served)
    )
    perVersion;

  # name -> served upstream versions (current + history; same across py
  # versions), read by the update driver to prune revision state.
  wheelVersions = lib.mapAttrs (_: ds: lib.unique (map (d: d.version) ds)) (lib.groupBy (d: d.name) wheelDists);
  # Revision keys no served wheel carries are left by an upstream bump or a
  # dropped history entry. The update driver drops them; this note covers hand
  # bumps. Only this registry's prefix; WebC keys get a note per package.
  staleRels = lib.concatMap (
    key: let
      name = lib.removePrefix relPrefix key;
    in
      lib.optionals (lib.hasPrefix relPrefix key)
      (map (v: "${key} ${v}")
        (lib.filter (v: !(lib.elem v (wheelVersions.${name} or [])))
          (lib.attrNames rels.${key})))
  ) (lib.attrNames rels);

  indexer = pkgs.writeShellApplication {
    name = "wasinix-python-index";
    runtimeInputs = [pkgs.python3];
    text = ''
      exec python3 ${./make-index.py} "$@"
    '';
  };

  registry =
    pkgs.runCommand "wasix-python-registry" {
      nativeBuildInputs = [indexer];
      distsJson = builtins.toJSON wheelDists;
      passAsFile = ["distsJson"];
    } ''
      wasinix-python-index "$distsJsonPath" "$out"
    '';

  # e2e/import tests run on the default python webc, installing from the merged index.
  tests =
    import ./tests.nix {
      inherit pkgs lib registry testLib pythonWebc python3;
    }
    // import ./resolve-sweep.nix {
      inherit pkgs lib registry testLib projectInterpreters;
    };
in
  registry.overrideAttrs (o: {
    passthru =
      (o.passthru or {})
      // {
        tests = mkTestGroup "python-registry" {behavior = tests;};
        inherit indexer wheelVersions wheels published;
        wasinix.update.notes = lib.optional (staleRels != []) {
          message = "release-revisions.json has stale keys (${lib.concatStringsSep ", " staleRels}); nix run .#update -- nixpkgs drops them";
          when = _: _: true;
        };
      };
  })
