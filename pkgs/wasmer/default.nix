# The wasmer (webc) layer. Each shipped CLI is its wasm cross build plus two
# passthru attrs: .pkg (the wasmer package from make-wasmer-package, configured
# via passthru.wasmer) and .tests (tests discovered from the package's
# overlay/packages/<name>/tests/ dir, run under wasmer via test-lib).
{
  lib,
  pkgs,
  # wasmer runtime for passthru.tests; null -> pkgs.wasmer.
  wasmer ? null,
  makeWasmerPackage,
  posOf,
  preferredProfilePackages,
  # the default-profile cross set, for tests that cross-build a consumer
  # program (e.g. icu-data's smoke test).
  crossPkgs,
  # overlay attr names of the CLIs to ship, resolved at their preferred profile.
  shippedCommands,
  # overlay/packages dir, used to locate each package's tests/.
  packagesDir,
}: let
  testLib = import ./test-lib.nix {inherit pkgs wasmer;};
  mkTestGroup = import ../lib/test-group.nix {inherit pkgs lib posOf;};

  # Collect tests from packages/<overlayName>/tests/: every *.nix file except
  # helpers.nix contributes tests, called with only the args it declares. The
  # group derivation runs all tests and exposes each one as a sub-attribute.
  testGroupFor = overlayName: let
    dir = packagesDir + "/${overlayName}/tests";
  in
    if !(builtins.pathExists dir)
    then null
    else let
      helpers =
        if builtins.pathExists (dir + "/helpers.nix")
        then import (dir + "/helpers.nix") {inherit pkgs;}
        else {};
      scope = {
        inherit pkgs testLib helpers crossPkgs makeWasmerPackage;
        # run-by-name stubs, keyed like wasmerPackages. Reading a shim never
        # forces .tests, so a test using another package (git needing bash)
        # does not cycle. The packed .webc is what ships, hence .shim rather
        # than .pkg.shim (which drives the wasmer.toml source dir).
        wasmerPkgs = lib.mapAttrs (_: p: p.shim) wasmerPackages;
      };
      testFiles = lib.attrNames (lib.filterAttrs
        (n: t: t == "regular" && lib.hasSuffix ".nix" n && n != "helpers.nix")
        (builtins.readDir dir));
      tests =
        builtins.foldl' (
          acc: fname: let
            f = import (dir + "/${fname}");
            # each test drv points at the file defining it
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
      mkTestGroup overlayName tests;

  # Add .pkg (the wasmer package dir), .webc (its built webc), and (if
  # present) .tests passthru to a cross package. Forcing the package or its
  # .pkg.shim never forces .tests, so tests referencing other packages'
  # shims (e.g. git tests using bash) do not cycle.
  augment = overlayName: crossPkg: servedVersions: let
    group = testGroupFor overlayName;
    pkg = makeWasmerPackage {
      package = crossPkg;
      inherit servedVersions;
    };
  in
    crossPkg.overrideAttrs (o: {
      passthru =
        # Drop inherited nixpkgs passthru.tests (native tests that would leak
        # into our `checks`).
        removeAttrs (o.passthru or {}) ["tests"]
        // {
          # The overlay attr this webc was built from (gitMinimal -> "git"
          # webc, but history.json / the loader key by overlay attr); lets
          # scripts/history.py and scripts/update.py map a webc back to its
          # history table entry. Passthru-only, no drvPath effect.
          inherit overlayName;
          inherit pkg;
          webc = pkg.webc;
          # run-by-name wrapper, top-level like .webc; forcing it never forces
          # .tests. Drives the packed .webc (what ships); .pkg.shim drives the
          # wasmer.toml source dir.
          shim = pkg.webc.shim;
        }
        // (lib.optionalAttrs (group != null) {tests = group;});
    });

  # Shipped commands keyed by webc/program name (gitMinimal -> "git").
  # History versions (passthru.wasmer.history, e.g. jq_1_6) key as
  # <name>-<semver> so the by-name key stays the current version; both
  # publish under the same webc name at their own versions.
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
  # Alias attrs (icu-data -> icu-data76) legitimately repeat a key with the
  # same drv; only distinct drvs sharing a key are an error. Singletons can't
  # conflict, so they skip the drvPath compare.
  byKey = lib.groupBy (i: i.key) shippedInfo;
  distinctDrvs = is: lib.length (lib.unique (map (i: i.crossPkg.drvPath) is));
  conflicting =
    lib.attrNames
    (lib.filterAttrs (_: is: lib.length is > 1 && distinctDrvs is > 1) byKey);
  wasmerPackages =
    lib.throwIf (conflicting != [])
    "wasmerPackages: duplicate webc keys (${lib.concatStringsSep ", " conflicting}); a second version of a name must set passthru.wasmer.history"
    (lib.mapAttrs (
        _: is: let
          i = lib.head is;
        in
          augment i.overlayName i.crossPkg servedByName.${i.id.name}
      )
      byKey);

  # One subtree per wasmerPackages key: two versions of one webc share the
  # inner pkg/<name> dir name, so a flat merge would collide. The publisher
  # globs **/wasmer.toml and doesn't care about the layout.
  allWasmerPackages = pkgs.runCommand "wasix-all-wasmer" {} ''
    set -euo pipefail
    mkdir -p "$out/pkg"
    ${lib.concatMapStringsSep "\n" (n: ''
        if [ -d "${wasmerPackages.${n}.pkg}/pkg" ]; then
          mkdir -p "$out/pkg/${n}"
          ${pkgs.coreutils}/bin/cp -R --no-preserve=mode,ownership "${wasmerPackages.${n}.pkg}/pkg/." "$out/pkg/${n}/"
        fi
      '')
      (builtins.attrNames wasmerPackages)}
  '';
in {
  inherit wasmerPackages allWasmerPackages testLib;
}
