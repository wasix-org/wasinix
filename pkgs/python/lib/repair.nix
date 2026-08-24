{
  lib,
  mergeScript,
}: package: let
  python = package.pythonModule;
  buildPython = python.pythonOnBuildForHost;
  passthru = package.passthru or {};
  metadata = passthru.wasix or {};
  historical = metadata ? historySpec;
  historyRepaired = metadata.pythonHistoryRepaired or false;
  historyBackends = buildPython.withPackages (packages: [
    packages.pdm-backend
    packages.hatchling
    packages.flit-core
    packages.poetry-core
    packages.cython
  ]);
  unboundBuildTools = ''
    if [ -f pyproject.toml ]; then
      sed -i -E '/^\[build-system\]/,/^\[[a-z]/{/build-backend/!s/"([A-Za-z0-9_.-]+)[<>=!~ ,.0-9a-z*]*"/"\1"/g}' pyproject.toml
    fi
  '';
in
  package.overrideAttrs (old:
    {
      PYTHONDONTWRITEBYTECODE = "1";
      passthru =
        (old.passthru or {})
        // {
          requiredPythonModules = python.pkgs.requiredPythonModules (old.propagatedBuildInputs or []);
        }
        // lib.optionalAttrs historical {
          wasix = ((old.passthru or {}).wasix or {}) // {pythonHistoryRepaired = true;};
        };
    }
    // lib.optionalAttrs (historical && !historyRepaired) {
      nativeBuildInputs =
        builtins.filter
        (input: (input.name or "") != "pyproject-version-patch-hook.sh")
        (old.nativeBuildInputs or [])
        ++ [
          buildPython.pkgs.setuptools
          buildPython.pkgs.wheel
        ];
      preBuild = mergeScript [
        (old.preBuild or "")
        ''
          historyBasePythonPath="$PYTHONPATH"
          export PYTHONPATH="${historyBackends}/${buildPython.sitePackages}:$PYTHONPATH"
        ''
      ];
      postBuild = mergeScript [
        (old.postBuild or "")
        ''
          export PYTHONPATH="$historyBasePythonPath"
        ''
      ];
      preInstallPhases = "historyDepPathPhase";
      historyDepPathPhase = ''
        export PYTHONPATH="${lib.concatMapStringsSep ":" (dependency: "${dependency}/${python.sitePackages}")
          (builtins.filter lib.isDerivation (old.propagatedBuildInputs or []))}:$PYTHONPATH"
      '';
      postPatch = mergeScript [(old.postPatch or "") unboundBuildTools];
    })
