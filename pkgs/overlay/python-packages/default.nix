# wasix overrides for the Python package set, the analogue of overlay/packages/.
# Each <name>.nix takes the top-level callArgs plus {pyfinal, pyprev} and returns
# the override of pyprev.<name>. Most packages need no entry: cross builds already
# skip the run-only phases (doCheck, pythonImportsCheck).
{callArgs}: pyfinal: pyprev: let
  inherit (callArgs) lib helpers;
  buildPy = pyprev.python.pythonOnBuildForHost;
  # An older release declares whichever build backend its project used then, and
  # what the rebase carries over is the current version's. Supply the common ones
  # from the build host: a release predating any backend falls back to
  # setuptools.build_meta, langchain 0.3 wants pdm.backend, and the cross set's
  # copies cannot run at build time.
  #
  # These are build-host dists and pythonRuntimeDepsCheckHook reads PYTHONPATH,
  # where a build-host packaging shadows the cross one and a release capping it
  # reads as unsatisfied. The wheel is finished by postBuild, so the backends only
  # need the path until then. setuptools and wheel propagate nothing and can stay.
  historyBackends = buildPy.withPackages (ps: [
    ps.pdm-backend
    ps.hatchling
    ps.flit-core
    ps.poetry-core
    # a release that cythonises its own sources needs the generator, not a
    # target build of it
    ps.cython
  ]);
  # An older release caps its build tools at versions that predate the ones we
  # build with (setuptools<82.1, pythran<0.17), and pypa/build checks those bounds
  # against what is actually installed. The pins are about the release's own CI,
  # not about what can compile it. Only [build-system] is unbounded: the same
  # names appear under [project] as runtime dependencies, and the wheel's metadata
  # has to keep the bounds the release published. An entry carrying an extra or an
  # environment marker does not match and keeps its bound.
  unboundBuildTools = ''
    if [ -f pyproject.toml ]; then
      sed -i -E '/^\[build-system\]/,/^\[[a-z]/{/build-backend/!s/"([A-Za-z0-9_.-]+)[<>=!~ ,.0-9a-z*]*"/"\1"/g}' pyproject.toml
    fi
  '';
  historyFixups = drv:
    if drv.passthru.wasmer.history or false
    then
      drv.overrideAttrs (o: {
        # pyprojectVersionPatchHook rewrites a pyproject version that disagrees with
        # the derivation's. A rebased build takes both from the same release, so the
        # hook either finds them equal or finds nothing to patch, and exits 1 either
        # way.
        nativeBuildInputs =
          builtins.filter
          (p: (p.name or "") != "pyproject-version-patch-hook.sh")
          (o.nativeBuildInputs or [])
          ++ [
            buildPy.pkgs.setuptools
            buildPy.pkgs.wheel
          ];
        preBuild = helpers.mergeScript [
          (o.preBuild or "")
          ''
            historyBasePythonPath="$PYTHONPATH"
            export PYTHONPATH="${historyBackends}/${buildPy.sitePackages}:$PYTHONPATH"
          ''
        ];
        postBuild = helpers.mergeScript [
          (o.postBuild or "")
          ''
            export PYTHONPATH="$historyBasePythonPath"
          ''
        ];
        # nixpkgs takes build-system deps from the cross set, so a build backend
        # propagates its own copy of a runtime dependency onto PYTHONPATH.
        # pythonRuntimeDepsCheckHook reads that path, so it sees the tool's copy
        # rather than the one this wheel propagates and a release capping the
        # version reads as unsatisfied. Put the wheel's own deps first.
        preInstallPhases = "historyDepPathPhase";
        historyDepPathPhase = ''
          export PYTHONPATH="${lib.concatMapStringsSep ":" (p: "${p}/${pyprev.python.sitePackages}")
            (builtins.filter lib.isDerivation (o.propagatedBuildInputs or []))}:$PYTHONPATH"
        '';
        # mergeScript, not +: a postPatch that does not end in a newline would
        # otherwise run straight into the first line below it.
        postPatch = helpers.mergeScript [(o.postPatch or "") unboundBuildTools];
      })
    else drv;
  # scikit-learn pins the version meson reads, and nixpkgs unbounds three build
  # requirements by matching the current release's literal ranges, which an older
  # release spells differently, so that postPatch goes and the generic sed above
  # covers it. It cannot take a package file: declaring one makes the set fail to
  # evaluate with "unsupported system: wasm32-wasip1", so the correction rides
  # here, where only minted entries are reached.
  # scipy carries an upstream backport patch cut against the current release, so
  # its hunks miss on an older src; the charlen patches beside it are the port's
  # own and stay. Like scikit-learn it cannot take a package file, so this rides
  # here where only minted entries are reached.
  scipyFixup = drv:
    if (drv.pname or "") == "scipy" && (drv.passthru.wasmer.history or false)
    then
      drv.overrideAttrs (o: {
        patches =
          builtins.filter
          (p: builtins.match ".*charlen.*" (baseNameOf (toString p)) != null)
          (o.patches or []);
      })
    else drv;
  sklearnFixup = drv:
    if (drv.pname or "") == "scikit-learn" && (drv.passthru.wasmer.history or false)
    then
      drv.overrideAttrs (_: {
        postPatch =
          unboundBuildTools
          + ''
            sed -i "s|run_command('sklearn/_build_utils/version.py', check: true).stdout().strip(),|'$version',|" meson.build
          '';
      })
    else drv;
  # A build backend that imports the package writes bytecode beside it, and it
  # lands in the wheel. A py3-none-any artifact then differs per interpreter,
  # and the registry refuses the two as one filename with conflicting contents.
  noBuildBytecode = drv: drv.overrideAttrs (_: {PYTHONDONTWRITEBYTECODE = "1";});
in
  builtins.mapAttrs (_: drv: noBuildBytecode (scipyFixup (sklearnFixup (historyFixups drv))))
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
