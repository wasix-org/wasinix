# The wasmer (webc) layer. Each shipped CLI is its wasm cross build plus two
# passthru attrs: .webc (the webc package from make-wasmer-package, configured
# via passthru.wasmer) and .tests (tests discovered from the package's
# overlay/packages/<name>/tests/ dir, run under wasmer via test-lib).
{
  lib,
  pkgs,
  # wasmer runtime for passthru.tests; null -> pkgs.wasmer.
  wasmer ? null,
  makeWasmerPackage,
  preferredPackages,
  # overlay attr names of the CLIs to ship, resolved at their preferred profile.
  shippedCommands,
  # overlay/packages dir, used to locate each package's tests/.
  packagesDir,
}: let
  testLib = import ./test-lib.nix {inherit pkgs wasmer;};
  mkTestGroup = import ../lib/test-group.nix {inherit pkgs lib;};

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
        inherit pkgs testLib helpers;
        wasmerPkgs = wrappedPackages;
      };
      testFiles = lib.attrNames (lib.filterAttrs
        (n: t: t == "regular" && lib.hasSuffix ".nix" n && n != "helpers.nix")
        (builtins.readDir dir));
      tests =
        builtins.foldl' (
          acc: fname: let
            f = import (dir + "/${fname}");
          in
            acc // f (builtins.intersectAttrs (lib.functionArgs f) scope)
        ) {}
        testFiles;
    in
      mkTestGroup overlayName tests;

  # Add .webc and (if present) .tests passthru to a cross package. Forcing the
  # package or its .webc.shim never forces .tests, so tests referencing
  # wrappedPackages (e.g. git tests using bash) do not cycle.
  augment = overlayName: crossPkg: let
    group = testGroupFor overlayName;
  in
    crossPkg.overrideAttrs (o: {
      passthru =
        # Drop inherited nixpkgs passthru.tests (native tests that would leak
        # into our `checks`).
        removeAttrs (o.passthru or {}) ["tests"]
        // {webc = makeWasmerPackage {package = crossPkg;};}
        // (lib.optionalAttrs (group != null) {tests = group;});
    });

  # Shipped commands keyed by webc/program name (gitMinimal -> "git").
  shippedPackages = lib.listToAttrs (map (
      n: let
        crossPkg = preferredPackages.${n};
        wname = crossPkg.passthru.wasmer.name or crossPkg.meta.mainProgram or crossPkg.pname or n;
      in
        lib.nameValuePair wname (augment n crossPkg)
    )
    shippedCommands);

  # Run-by-name stubs (.webc.shim) per package, for cross-package tests;
  # accessing .shim does not force .tests.
  wrappedPackages =
    lib.mapAttrs (_: p: p.webc.shim)
    (lib.filterAttrs (_: p: p.webc ? shim) shippedPackages);

  allWasmer = pkgs.runCommand "wasix-all-wasmer" {} ''
    set -euo pipefail
    mkdir -p "$out/pkg"
    ${lib.concatMapStringsSep "\n" (n: ''
        if [ -d "${shippedPackages.${n}.webc}/pkg" ]; then
          ${pkgs.coreutils}/bin/cp -R --no-preserve=mode,ownership "${shippedPackages.${n}.webc}/pkg/." "$out/pkg/"
        fi
      '')
      (builtins.attrNames shippedPackages)}
  '';
in {
  inherit shippedPackages wrappedPackages allWasmer;
}
