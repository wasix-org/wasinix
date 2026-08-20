# scikit-learn for wasix, built against the cross-built libomp.
{
  pyprev,
  pyfinal,
  wasixPython,
  helpers,
  toolchain,
  lib,
  ...
}: let
  isHistory = (pyprev.scikit-learn.passthru.wasix.historySpec or null) != null;
  crossNumpyInc = wasixPython.pkgs.numpy.crossInclude;
  # openblas has no wasm build (scikit-learn reaches BLAS through scipy's cython
  # .pxd); nixpkgs' openmp needs an llvm-static that does not cross-build.
  dropUnwanted = xs:
    helpers.dropInputsByNameInfix ["openmp-static"]
    (helpers.dropInputsByName ["openblas" "blas" "lapack" "openmp"] xs);
in
  helpers.libTweaks {
    # The full estimator matrix takes roughly 35 minutes under emulation.
    passthru.wasinix.checks.captured = {
      shards = 8;
      timeout = 3600;
    };
    # joblib otherwise asks psutil for PID 1's affinity while configuring the
    # suite; WASIX has no process table or multiprocessing implementation.
    env.LOKY_MAX_CPU_COUNT = "1";
    env.JOBLIB_MULTIPROCESSING = "0";
    # psutil is left out of this list: its WASIX backend cannot inspect PID 1,
    # and joblib only uses it as an optional acceleration, not required by the
    # suite or package runtime.
    passthru.wasixDeclaredCheckInputs = [pyfinal.pytestCheckHook pyfinal.pytest-xdist pyfinal.hypothesis];
    # Meson's fallback asks the build Python for NumPy headers. Native
    # NPY_SIZEOF_LONG=8 corrupts buffer formats in wasm extensions, where it is 4.
    postPatch = old:
      helpers.mergeScript [
        (
          if isHistory
          then ''
            sed -i "s|run_command('sklearn/_build_utils/version.py', check: true).stdout().strip(),|'$version',|" meson.build
            grep -q "'$version'," meson.build
          ''
          else old
        )
        ''
          substituteInPlace sklearn/meson.build \
            --replace-fail \
              "incdir_numpy = meson.get_external_property('numpy-include-dir', 'not-given')" \
              "incdir_numpy = '${crossNumpyInc}'"
          substituteInPlace sklearn/preprocessing/tests/test_polynomial.py \
            --replace-fail \
              'sys.maxsize <= 2**32 and sys.platform != "emscripten"' \
              'sys.maxsize <= 2**32 and sys.platform not in {"emscripten", "wasix"}'
        ''
      ];
    # The cross python mirrors buildInputs into propagatedBuildInputs.
    buildInputs = old: dropUnwanted old ++ [toolchain.openmp];
    propagatedBuildInputs = dropUnwanted;
  }
  pyprev.scikit-learn
