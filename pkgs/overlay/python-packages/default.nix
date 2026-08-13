# wasix overrides for the Python package set, the analogue of overlay/packages/.
# Each <name>.nix takes the top-level callArgs plus {pyfinal, pyprev} and returns
# the override of pyprev.<name>. Most packages need no entry: cross builds already
# skip the run-only phases (doCheck, pythonImportsCheck).
{callArgs}: pyfinal: pyprev: let
  buildPy = pyprev.python.pythonOnBuildForHost;
  # A release old enough to predate its project's move to a modern build backend
  # declares none, so pypa/build falls back to setuptools.build_meta and needs
  # setuptools present. The current version's build-system is what the rebase
  # carries over, and the cross set's copy cannot run at build time.
  historyFixups = drv:
    if drv.passthru.wasmer.history or false
    then
      drv.overrideAttrs (o: {
        nativeBuildInputs =
          (o.nativeBuildInputs or [])
          ++ [buildPy.pkgs.setuptools buildPy.pkgs.wheel];
      })
    else drv;
  # A build backend that imports the package writes bytecode beside it, and it
  # lands in the wheel. A py3-none-any artifact then differs per interpreter,
  # and the registry refuses the two as one filename with conflicting contents.
  noBuildBytecode = drv: drv.overrideAttrs (_: {PYTHONDONTWRITEBYTECODE = "1";});
in
  builtins.mapAttrs (_: drv: noBuildBytecode (historyFixups drv))
  (
    (callArgs.helpers.loadPackageDir {
      dir = ./.;
      # the ship/test worklist, not an override function
      exclude = ["wheels"];
      # <name>_<version> attrs, minted by rebasing pyprev.<name> onto the entry's src
      history = builtins.fromJSON (builtins.readFile ./history.json);
      historyFrom = "pyprev";
    })
    .mkPackages {
      callArgs = callArgs // {inherit pyfinal pyprev;};
    }
  )
