# wasix overrides for the Python package set — the python-package analogue of
# overlay/packages/. Auto-imports every overlay/python-packages/<name>.nix and folds it into
# a cpython `packageOverrides` function (pyfinal: pyprev: { ... }), which python3.nix passes to
# its .override (alongside `self`, so the whole set builds against our wasix python).
#
# Each <name>.nix is a function:
#   { pyfinal, pyprev, final, prev, preferredPackages, helpers, lib }
#   -> the wasix override of pyprev.<name>
# Use pyfinal/pyprev for Python deps (same set, auto-threaded) and final.<x> for top-level
# (C-library) deps. Put patch files under overlay/python-packages/patches/.
#
# Most packages need NO entry: nixpkgs' cross machinery already skips the run-only phases
# (doCheck / pythonImportsCheck can't execute wasm at build time). Add a file here only when a
# package needs real build fixes — cross-compile breakage, a C-extension source patch, or a
# dependency swapped for its wasix build.
{
  lib,
  callArgs,
}: pyfinal: pyprev: let
  entries = builtins.readDir ./.;
  # "wheels" is the ship/test worklist (a list, consumed by pkgs/python-wheels.nix),
  # not a package override function — skip it like "default".
  fileNames =
    builtins.filter (n: n != "default" && n != "wheels")
    (map (lib.removeSuffix ".nix")
      (lib.attrNames (lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".nix" n) entries)));
in
  lib.genAttrs fileNames
  (n: import (./. + "/${n}.nix") (callArgs // {inherit pyfinal pyprev;}))
