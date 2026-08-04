# wasix overrides for the Python package set, the analogue of overlay/packages/.
# Each <name>.nix takes the top-level callArgs plus {pyfinal, pyprev} and returns
# the override of pyprev.<name>. Most packages need no entry: cross builds already
# skip the run-only phases (doCheck, pythonImportsCheck).
{callArgs}: pyfinal: pyprev:
(callArgs.helpers.loadPackageDir {
  dir = ./.;
  # the ship/test worklist, not an override function
  exclude = ["wheels"];
  # <name>_<version> attrs, minted by rebasing pyprev.<name> onto the entry's src
  history = builtins.fromJSON (builtins.readFile ./history.json);
  historyFrom = "pyprev";
}).mkPackages {
  callArgs = callArgs // {inherit pyfinal pyprev;};
}
