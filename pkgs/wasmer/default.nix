# The wasmer (webc) layer: each shipped CLI is its wasm cross build plus .pkg
# (the wasmer package) and .tests (from overlay/packages/<name>/tests/).
{
  lib,
  pkgs,
  # wasmer runtime for passthru.tests; null -> pkgs.wasmer.
  wasmer ? null,
  makeWasmerPackage,
  posOf,
  preferredProfilePackages,
  # the default-profile cross set, for tests that cross-build a consumer program
  crossPkgs,
  # for tests whose subject is PIC-only
  crossPkgsPic,
  # overlay attr names of the CLIs to ship, resolved at their preferred profile.
  shippedCommands,
  # overlay/packages dir, used to locate each package's tests/.
  packagesDir,
  # the served wheel index, for tests that resolve against it. Forced only by a
  # test, and it reads preferredProfilePackages.python3.shim, which never forces
  # .tests.
  pythonRegistry,
  # drv -> its declared emulated build-system checks (pkgs/emulated-check.nix).
  emulatedChecksFor ? (_: {}),
}: let
  testLib = import ./test-lib.nix {inherit pkgs wasmer;};
  mkTestGroup = import ../lib/test-group.nix {inherit pkgs lib posOf;};

  # Collect tests from packages/<overlayName>/tests/: every *.nix file except
  # helpers.nix contributes tests, called with only the args it declares, joined
  # by `extraTests` (the package's declared emulated check). The returned
  # namespace exposes each test directly and the aggregate as `all`.
  testGroupFor = overlayName: extraTests: let
    dir = packagesDir + "/${overlayName}/tests";
  in
    if !(builtins.pathExists dir)
    then
      (
        if extraTests == {}
        then null
        else mkTestGroup overlayName extraTests
      )
    else let
      helpers =
        if builtins.pathExists (dir + "/helpers.nix")
        then import (dir + "/helpers.nix") {inherit pkgs;}
        else {};
      scope = {
        inherit pkgs testLib helpers crossPkgs crossPkgsPic makeWasmerPackage pythonRegistry;
        preferredProfilePackages = preferredProfilePackagesWithWebc;
        # Shims, for putting another package's commands on PATH. .shim drives the
        # packed .webc, .pkg.shim the source dir.
        wasmerPkgs = lib.mapAttrs (_: p: p.shim) wasmerPackages;
        # The packages themselves, for a test that needs a .webc or .pkg rather
        # than something runnable. Reaching for another package's .tests from
        # here would cycle; nothing stops you, so don't.
        inherit wasmerPackages;
      };
      testFiles = lib.attrNames (lib.filterAttrs
        (n: t: t == "regular" && lib.hasSuffix ".nix" n && n != "helpers.nix")
        (builtins.readDir dir));
      tests =
        builtins.foldl' (
          acc: fname: let
            f = import (dir + "/${fname}");
            stamp = drv:
              drv.overrideAttrs (_old: {
                pos = {
                  file = toString (dir + "/${fname}");
                  line = 1;
                };
              });
          in
            acc // lib.mapAttrs (_: stamp) (f (builtins.intersectAttrs (lib.functionArgs f) scope))
        ) {}
        testFiles;
    in
      mkTestGroup overlayName ({behavior = tests;} // extraTests);

  cliSmoke = import ./cli-smoke.nix {inherit lib testLib;};

  # Forcing the package or its .pkg.shim never forces .tests, so tests referencing
  # other packages' shims do not cycle.
  augment = overlayName: packageKey: crossPkg: servedVersions: let
    group = testGroupFor overlayName (emulatedChecksFor crossPkg);
    pkg = makeWasmerPackage {
      package = crossPkg;
      inherit servedVersions;
    };
    # With no hand-written suite and no emulated check, fall back to the
    # liveness smoke so every shipped CLI runs under wasmer at least once. A
    # webc shipping no command opts out with passthru.wasmer.smokeArgs = [].
    smokeArgs = crossPkg.passthru.wasmer.smokeArgs or null;
    effGroup =
      if group != null
      then group
      else if smokeArgs == []
      then null
      else
        mkTestGroup overlayName {
          behavior.smoke = cliSmoke overlayName crossPkg pkg.webc.shim;
        };
  in
    crossPkg.overrideAttrs (o: {
      passthru =
        # nixpkgs' own passthru.tests are native, and would leak into `checks`
        removeAttrs (o.passthru or {}) ["tests"]
        // {
          # git -> "git" webc, but history.json keys by overlay attr, so
          # `history` and `update` need this to map a webc back to its entry.
          inherit overlayName;
          wasmer = ((o.passthru or {}).wasmer or {}) // {inherit packageKey;};
          inherit pkg;
          webc = pkg.webc;
          # run-by-name wrapper; forcing it never forces .tests
          shim = pkg.webc.shim;
          wasix =
            ((o.passthru or {}).wasix or {})
            // {inherit (pkg.passthru.wasix) publication;};
        }
        // (lib.optionalAttrs (effGroup != null) {tests = effGroup;});
    });

  # Keyed by webc/program name (git -> "git"); a history version keys as
  # <name>-<semver>, so the by-name key stays the current version.
  ident = import ./ident.nix {inherit lib;};
  shippedInfo =
    map (n: rec {
      overlayName = n;
      crossPkg = preferredProfilePackages.${n};
      id = ident.webcIdent crossPkg;
      history = crossPkg.passthru.wasmer.history or false;
      key =
        if history
        then "${id.name}-${id.baseVersion}"
        else id.name;
    })
    shippedCommands;
  servedByName =
    lib.mapAttrs (_: infos: lib.unique (map (i: i.id.baseVersion) infos))
    (lib.groupBy (i: i.id.name) shippedInfo);
  shippedPackages =
    lib.listToAttrs
    (map (i:
      lib.nameValuePair i.overlayName
      (augment i.overlayName i.key i.crossPkg servedByName.${i.id.name}))
    shippedInfo);
  preferredProfilePackagesWithWebc = preferredProfilePackages // shippedPackages;
  # Alias attrs (icu-data -> icu-data76) repeat a key with the same drv; only
  # distinct drvs sharing a key are an error.
  byKey = lib.groupBy (i: i.key) shippedInfo;
  distinctDrvs = is: lib.length (lib.unique (map (i: i.crossPkg.drvPath) is));
  conflicting =
    lib.attrNames
    (lib.filterAttrs (_: is: lib.length is > 1 && distinctDrvs is > 1) byKey);
  wasmerPackageInventory =
    lib.throwIf (conflicting != [])
    "wasmerPackages: duplicate webc keys (${lib.concatStringsSep ", " conflicting}); a second version of a name must set passthru.wasmer.history"
    (lib.mapAttrs (_: is: shippedPackages.${(lib.head is).overlayName}) byKey);
  aliasInfo = lib.concatLists (lib.mapAttrsToList (packageKey: is:
    map (name: {
      inherit name packageKey;
      package = wasmerPackageInventory.${packageKey};
    }) ((lib.head is).crossPkg.passthru.wasmer.aliases or []))
  byKey);
  byAlias = lib.groupBy (i: i.name) aliasInfo;
  conflictingAliases = lib.attrNames (lib.filterAttrs (_: is:
    lib.length (lib.unique (map (i: i.packageKey) is)) > 1)
  byAlias);
  shadowingAliases = lib.intersectLists (lib.attrNames wasmerPackageInventory) (lib.attrNames byAlias);
  aliasPackages = lib.mapAttrs (_: is: (lib.head is).package) byAlias;
  wasmerPackages =
    lib.throwIf (shadowingAliases != [])
    "wasmerPackages: aliases shadow canonical keys (${lib.concatStringsSep ", " shadowingAliases})"
    (lib.throwIf (conflictingAliases != [])
      "wasmerPackages: aliases resolve to multiple packages (${lib.concatStringsSep ", " conflictingAliases})"
      (wasmerPackageInventory // aliasPackages));

  # One subtree per key: two versions of one webc share the inner pkg/<name> dir
  # name, so a flat merge would collide.
  allWasmerPackages = pkgs.runCommand "wasix-all-wasmer" {} ''
    set -euo pipefail
    mkdir -p "$out/pkg"
    ${lib.concatMapStringsSep "\n" (n: ''
        if [ -d "${wasmerPackageInventory.${n}.pkg}/pkg" ]; then
          mkdir -p "$out/pkg/${n}"
          ${pkgs.coreutils}/bin/cp -R --no-preserve=mode,ownership "${wasmerPackageInventory.${n}.pkg}/pkg/." "$out/pkg/${n}/"
        fi
      '')
      (builtins.attrNames wasmerPackageInventory)}
  '';
  # Non-shipped library packages use the same tests/ convention as shipped CLIs but
  # have no webc to hang .tests off, so the group attaches to the package itself.
  libraryTestPkgs = let
    entries = builtins.readDir packagesDir;
    names =
      lib.filter (
        n:
          entries.${n}
          == "directory"
          && !(lib.elem n shippedCommands)
          && builtins.pathExists (packagesDir + "/${n}/tests")
      )
      (lib.attrNames entries);
  in
    lib.genAttrs names (
      n:
        (preferredProfilePackages.${n}).overrideAttrs (o: {
          passthru =
            removeAttrs (o.passthru or {}) ["tests"]
            // {tests = testGroupFor n {};};
        })
    );
in {
  preferredProfilePackages = preferredProfilePackagesWithWebc;
  inherit wasmerPackages wasmerPackageInventory allWasmerPackages testLib libraryTestPkgs;
}
