# The wasmer (webc) layer. A shipped CLI IS its package (the wasm cross build),
# carrying two passthru attrs:
#   .webc  — the webc package, built by make-wasmer-package (which derives
#            name/version/commands/… and reads per-package deviations from
#            passthru.wasmer);
#   .tests — behavioural tests discovered from the package's own
#            overlay/packages/<name>/tests/ dir, run under wasmer via test-lib.
# So `shippedPackages.git` is the wasm, `.git.webc` the webc package, `.git.tests`
# its tests — everything hangs off the one package.
{
  lib,
  pkgs,
  # the wasmer runtime for passthru.tests (the flake input; null -> pkgs.wasmer).
  wasmer ? null,
  makeWasmerPackage,
  preferredPackages,
  # overlay attr-names of the CLIs to ship; each resolved at its preferred profile.
  shippedCommands,
  # overlay/packages, to find each package's co-located tests/.
  packagesDir,
  # extra shipped CROSS packages not drawn from preferredPackages (crabsay), as
  # { <overlayName> = crossPkg; }.
  extraShipped ? {},
}: let
  testLib = import ./test-lib.nix {inherit pkgs wasmer;};
  mkTestGroup = import ../test-group.nix {inherit pkgs lib;};

  # Build the test group from packages/<overlayName>/tests/ (if present): every
  # *.nix there (except helpers.nix) auto-registers, given only the args it asks
  # for. The group is a derivation that runs all tests AND carries each as a
  # sub-attr, so `pkg.tests` runs everything and `pkg.tests.<t>` runs just one.
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

  # Augment a shipped cross package with its webc build (.webc) and co-located
  # tests (.tests, if any). Lazy: forcing the package — or its .webc.shim — never
  # forces .tests, so cross-package tests (git -> bash) referencing wrappedPackages
  # don't cycle. The webc is built from the original crossPkg (same bin), so the
  # augmented package referencing its own .webc is fine.
  augment = overlayName: crossPkg: let
    group = testGroupFor overlayName;
  in
    crossPkg.overrideAttrs (o: {
      passthru =
        # drop any inherited nixpkgs passthru.tests (those are x86 tests, and would
        # otherwise leak into our `checks`); set ours only when the package has a
        # tests/ dir.
        removeAttrs (o.passthru or {}) ["tests"]
        // {webc = makeWasmerPackage {package = crossPkg;};}
        // (lib.optionalAttrs (group != null) {tests = group;});
    });

  # Keyed by webc/program name (gitMinimal -> "git"): the shipped commands at
  # their preferred profile, plus the extras (crabsay).
  shippedPackages =
    lib.listToAttrs (map (
        n: let
          crossPkg = preferredPackages.${n};
          wname = crossPkg.passthru.wasmer.name or crossPkg.meta.mainProgram or crossPkg.pname or n;
        in
          lib.nameValuePair wname (augment n crossPkg)
      )
      shippedCommands)
    // lib.mapAttrs augment extraShipped;

  # `.webc.shim` (run-by-name stub) per package, for cross-package tests. `.shim`
  # doesn't touch `.tests`, so this stays lazy.
  wrappedPackages =
    lib.mapAttrs (_: p: p.webc.shim)
    (lib.filterAttrs (_: p: p.webc ? shim) shippedPackages);

  allWasmer = pkgs.runCommand "wasix-all-wasmer" {} ''
    set -euo pipefail
    mkdir -p "$out/pkg"
    ${lib.concatMapStringsSep "\n" (n: ''
        if [ -d "${shippedPackages.${n}.webc}/pkg" ]; then
          # Do not preserve top-level directory permissions from Nix store paths.
          ${pkgs.coreutils}/bin/cp -R --no-preserve=mode,ownership "${shippedPackages.${n}.webc}/pkg/." "$out/pkg/"
        fi
      '')
      (builtins.attrNames shippedPackages)}
  '';
in {
  inherit shippedPackages wrappedPackages allWasmer;
}
