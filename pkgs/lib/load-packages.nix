# The one auto-import convention for wasix package sets. A package is either a
# flat <dir>/<name>.nix file or a <dir>/<name>/package.nix directory (which also
# holds its patches/tests/aux files); packages needing no tweaks at all can be
# listed in `trivial` instead of getting a file. Non-package files/dirs are
# ignored: default.nix (the set's own loader) and dirs without a package.nix
# (e.g. a shared patches/ dir).
#
# Used by the top-level overlay AND the python packageOverrides, so the
# convention can't drift between sets. `names` is eval-only (no callArgs), which
# is how pkgs/default.nix enumerates the package set without instantiating one.
{lib}: {
  dir,
  trivial ? [],
  # extra non-package .nix files to skip (e.g. a worklist the set carries).
  exclude ? [],
}: let
  entries = builtins.readDir dir;
  fileNames =
    builtins.filter (n: !(builtins.elem n (["default"] ++ exclude)))
    (map (lib.removeSuffix ".nix")
      (lib.attrNames (lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) entries)));
  dirNames =
    builtins.filter (n: builtins.pathExists (dir + "/${n}/package.nix"))
    (lib.attrNames (lib.filterAttrs (_: t: t == "directory") entries));
in {
  names = fileNames ++ dirNames ++ trivial;

  # Instantiate the set: every package file is a function over one `callArgs`
  # attrset; trivial names go through `mkTrivial`.
  mkPackages = {
    callArgs,
    mkTrivial ? name: throw "load-packages: '${name}' is in the trivial list but no mkTrivial was given",
  }:
    (lib.genAttrs trivial mkTrivial)
    // (lib.genAttrs fileNames (n: import (dir + "/${n}.nix") callArgs))
    // (lib.genAttrs dirNames (n: import (dir + "/${n}/package.nix") callArgs));
}
