# wasix overrides for the Python package set, the analogue of overlay/packages/
# (same auto-import convention). Folded into a cpython `packageOverrides`
# function that python3/package.nix passes to its .override (with `self`, so
# the whole set builds against our wasix python).
#
# Each <name>.nix is a function over the same callArgs as a top-level package
# file plus { pyfinal, pyprev }, returning the override of pyprev.<name>. Use
# pyfinal/pyprev for Python deps and final.<x> for C-library deps; patches go
# under patches/.
#
# Most packages need no entry: cross builds already skip the run-only phases
# (doCheck / pythonImportsCheck can't execute wasm). Add a file only for real
# build fixes.
{callArgs}: pyfinal: pyprev:
(callArgs.helpers.loadPackageDir {
  dir = ./.;
  # "wheels" is the ship/test worklist (consumed by pkgs/python-wheels.nix),
  # not an override function; skip it.
  exclude = ["wheels"];
}).mkPackages {
  callArgs = callArgs // {inherit pyfinal pyprev;};
}
