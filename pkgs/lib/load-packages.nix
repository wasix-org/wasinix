# Auto-import convention for wasix package sets: a package is <dir>/<name>.nix,
# <dir>/<name>/package.nix, or (if it needs no tweaks) a name in `trivial`.
# A dir's package.nix may also evaluate to {names, packages} instead of a
# function: a multi-package dir (version families like icu). `names` is the
# static attr list it provides; `packages = callArgs: {<name> = drv;}`.
# default.nix and dirs without a package.nix (e.g. shared patches/) are ignored.
# Used by both the top-level overlay and the python packageOverrides, so the
# convention can't drift between sets. `names` is eval-only (no callArgs),
# letting pkgs/default.nix enumerate the set without instantiating one.
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
  dirEntry = n: import (dir + "/${n}/package.nix");
  isMulti = e: !builtins.isFunction e;
in {
  names =
    fileNames
    ++ lib.concatMap (
      n: let
        e = dirEntry n;
      in
        if isMulti e
        then e.names
        else [n]
    )
    dirNames
    ++ trivial;

  # Instantiate the set: every package file is a function over one `callArgs`
  # attrset; trivial names go through `mkTrivial`.
  mkPackages = {
    callArgs,
    mkTrivial ? name: throw "load-packages: '${name}' is in the trivial list but no mkTrivial was given",
  }:
    (lib.genAttrs trivial mkTrivial)
    // (lib.genAttrs fileNames (n: import (dir + "/${n}.nix") callArgs))
    // (builtins.foldl' (
        acc: n: let
          e = dirEntry n;
        in
          acc
          // (
            if isMulti e
            then e.packages callArgs
            else {${n} = e callArgs;}
          )
      ) {}
      dirNames);
}
