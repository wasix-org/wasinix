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
        # An older release caps its build tools at versions that predate the ones
        # we build with (setuptools<82.1, meson-python<0.17), and pypa/build
        # checks those bounds against what is actually installed. The pins are
        # about the release's own CI, not about what can compile it.
        postPatch =
          (o.postPatch or "")
          + ''
            if [ -f pyproject.toml ]; then
              sed -i -E 's/"(setuptools|wheel|meson-python|meson|[Cc]ython|numpy|scipy|scikit-build-core|hatchling|hatch-vcs|hatch-fancy-pypi-readme|poetry-core|flit-core|pybind11|setuptools[_-]scm|cmake|ninja)[<>=!~ ,.0-9a-z]*"/"\1"/g' pyproject.toml
            fi
          '';
      })
    else drv;
  # scikit-learn pins the version meson reads and unbounds three build
  # requirements by matching the current release's literal ranges, which an older
  # release spells differently. It cannot take a package file: declaring one makes
  # the set fail to evaluate with "unsupported system: wasm32-wasip1", so the
  # correction rides here, where only minted entries are reached.
  sklearnFixup = drv:
    if (drv.pname or "") == "scikit-learn" && (drv.passthru.wasmer.history or false)
    then
      drv.overrideAttrs (_: {
        postPatch = ''
          sed -i "s|run_command('sklearn/_build_utils/version.py', check: true).stdout().strip(),|'$version',|" meson.build
        '';
      })
    else drv;
  # A build backend that imports the package writes bytecode beside it, and it
  # lands in the wheel. A py3-none-any artifact then differs per interpreter,
  # and the registry refuses the two as one filename with conflicting contents.
  noBuildBytecode = drv: drv.overrideAttrs (_: {PYTHONDONTWRITEBYTECODE = "1";});
in
  builtins.mapAttrs (_: drv: noBuildBytecode (sklearnFixup (historyFixups drv)))
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
