# wasix overrides for the Python package set — the python-package analogue of
# overlay/packages/, using the same auto-import convention (pkgs/lib/load-packages.nix).
# Folded into a cpython `packageOverrides` function (pyfinal: pyprev: { ... }), which
# python3/package.nix passes to its .override (alongside `self`, so the whole set builds
# against our wasix python).
#
# Each <name>.nix is a function over the same callArgs as a top-level package file, plus
#   { pyfinal, pyprev }
# -> the wasix override of pyprev.<name>
# Use pyfinal/pyprev for Python deps (same set, auto-threaded) and final.<x> for top-level
# (C-library) deps. Put patch files under overlay/python-packages/patches/.
#
# Most packages need NO entry: nixpkgs' cross machinery already skips the run-only phases
# (doCheck / pythonImportsCheck can't execute wasm at build time). Add a file here only when a
# package needs real build fixes — cross-compile breakage, a C-extension source patch, or a
# dependency swapped for its wasix build.
{callArgs}: pyfinal: pyprev:
(callArgs.helpers.loadPackageDir {
  dir = ./.;
  # "wheels" is the ship/test worklist (a list, consumed by pkgs/python-wheels.nix),
  # not a package override function — skip it like the loader skips default.nix.
  exclude = ["wheels"];
}).mkPackages {
  callArgs = callArgs // {inherit pyfinal pyprev;};
}
