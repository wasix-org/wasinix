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
        wasmerPkgs = wrappedPackages;
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
  # .pkg.shim never forces .tests, so tests referencing wrappedPackages
  # (e.g. git tests using bash) do not cycle.
  augment = overlayName: crossPkg: let
    group = testGroupFor overlayName;
    pkg = makeWasmerPackage {package = crossPkg;};
  in
    crossPkg.overrideAttrs (o: {
      passthru =
        # Drop inherited nixpkgs passthru.tests (native tests that would leak
        # into our `checks`).
        removeAttrs (o.passthru or {}) ["tests"]
        // {
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
  wasmerPackages = lib.listToAttrs (map (
      n: let
        crossPkg = preferredProfilePackages.${n};
        wname = crossPkg.passthru.wasmer.name or crossPkg.meta.mainProgram or crossPkg.pname or n;
      in
        lib.nameValuePair wname (augment n crossPkg)
    )
    shippedCommands);

  # Run-by-name stubs per package, for cross-package tests; accessing a shim
  # does not force .tests. Tests run the packed .webc (what ships), via
  # .pkg.webc.shim rather than .pkg.shim (the wasmer.toml source dir).
  wrappedPackages =
    lib.mapAttrs (_: p: p.pkg.webc.shim)
    (lib.filterAttrs (_: p: p.pkg ? shim) wasmerPackages);

  allWasmerPackages = pkgs.runCommand "wasix-all-wasmer" {} ''
    set -euo pipefail
    mkdir -p "$out/pkg"
    ${lib.concatMapStringsSep "\n" (n: ''
        if [ -d "${wasmerPackages.${n}.pkg}/pkg" ]; then
          ${pkgs.coreutils}/bin/cp -R --no-preserve=mode,ownership "${wasmerPackages.${n}.pkg}/pkg/." "$out/pkg/"
        fi
      '')
      (builtins.attrNames wasmerPackages)}
  '';
in {
  inherit wasmerPackages wrappedPackages allWasmerPackages testLib;
}
