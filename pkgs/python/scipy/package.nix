# scipy for wasix. openblas throws "unsupported system: wasm32-wasi" at eval, so
# the provider becomes the flang-built reference LAPACK. 1.18 builds no Fortran
# of its own (_without-fortran=true costs only scipy.odr); an older release does,
# through wasixflang, which compiles with flang and links through wasixcc.
{
  exposePackage,
  extendPackage,
  packages,
  package,
  pkgs,
  lib,
  dropFlagsByPrefix,
}:
exposePackage (
  let
    lapack = pkgs.lapack-reference;
    # The cross pythran does not eval (reads hostPlatform.extensions.sharedLibrary).
    buildPythran = packages.sameProfile.python.pythonOnBuildForHost.pkgs.pythran;
    # Boost.Build rejects architecture=wasm; boost.math is header-only anyway.
    buildBoost = pkgs.buildPackages.boost191;
    isHistory = (package.passthru.wasix.historySpec or null) != null;
    # A release caps numpy a minor or two past itself, and the set's numpy is
    # beyond both caps, so a rebase takes the newest history entry under its own.
    # The one argument feeds both the meson include dir and the propagated
    # dependency, so the wheel compiles against the release it then declares.
    historyNumpy =
      if lib.versionOlder package.version "1.15"
      then packages.sameProfile.numpy.versions."2.2.6"
      else packages.sameProfile.numpy.versions."2.3.5";
  in
    extendPackage (package.override ({
        blas = lapack;
        inherit lapack;
        pythran = buildPythran;
        boost191 = buildBoost;
      }
      // lib.optionalAttrs isHistory {numpy = historyNumpy;})) {
      # The full upstream suite collects roughly 96,000 cases under emulation.
      passthru.wasinix.checks.captured = {
        shards = 16;
        timeout = 7200;
        tags = ["slow-tests"];
      };
      passthru.wasinix.update.notes = [
        {message = "scipy: re-check the explicit f2py CHARACTER-length patch on bump.";}
      ];
      preCheck = _: ''
        _site=$(echo "$PYTHONPATH" | tr ':' '\n' | grep -m1 -- '-scipy-.*site-packages$')
        cd "$_site"
      '';
      # 1.16 added the use-system-libraries option, so an older release aborts on
      # the flag; the vendored copies it then falls back to are what it shipped.
      mesonFlags = old:
        dropFlagsByPrefix (
          ["-Dblas=" "-Dlapack="]
          ++ lib.optional (lib.versionOlder package.version "1.16") "-Duse-system-libraries="
        )
        old
        ++ [
          "-Dblas=blas"
          "-Dlapack=lapack"
        ]
        ++ (
          if lib.versionAtLeast package.version "1.18"
          then ["-D_without-fortran=true"]
          # its project defaults ask for gfortran's -std=legacy, which flang has no
          # equivalent of; meson offers "none" alone for this compiler
          else ["-Dfortran_std=none"]
        );

      # dependency('boost')'s system method errors unless both dirs are set.
      env.BOOST_INCLUDEDIR = "${buildBoost.dev}/include";
      env.BOOST_LIBRARYDIR = "${buildBoost}/lib";

      # scipy's callers omit the hidden CHARACTER-length args flang emits, which
      # traps under wasm's strictly-typed call_indirect; the patches append them.
      # 1.18 moved the generator's wrapper code, so an older release takes the
      # variant cut against the layout it still has.
      # nixpkgs carries an upstream cross-compilation backport cut against the
      # current release, whose hunks miss on an older src; ours are the port's own.
      patches = old:
        lib.optionals (!isHistory) old
        ++ [
          (
            if lib.versionOlder package.version "1.18"
            then ../patches/scipy-cython-blas-fortran-charlen-pre118.patch
            else ../patches/scipy-cython-blas-fortran-charlen.patch
          )
          ./scipy-f2py-callstatement-charlen.patch
          (
            if lib.versionOlder package.version "1.18"
            then ../patches/scipy-hand-c-blas-fortran-charlen-pre118.patch
            else ../patches/scipy-hand-c-blas-fortran-charlen.patch
          )
        ];

      # _test_internal calls fesetround(FE_UPWARD); wasm has no dynamic rounding
      # modes, so wasix-libc omits those fenv.h macros.
      postPatch =
        ''
          sed -i "/^py3.extension_module('_test_internal',$/,/^)$/d" scipy/special/meson.build
        ''
        + lib.optionalString (!isHistory) ''
          substituteInPlace scipy/conftest.py \
            --replace-fail 'and sys.platform != "cygwin":' 'and sys.platform not in {"cygwin", "wasix"}:'
        ''
        # show_config() reports where each dependency was found, and configure_file
        # bakes those store paths into __config__.py and from there into the wheel,
        # where the reference check cannot see them inside the zip. They are
        # build-time locations of statically linked libraries and of build host
        # tooling (pythran), so none of them mean anything to a wheel consumer.
        # Substituted in the template, which every release spells identically,
        # rather than per dependency in meson.build. "unknown" is what meson.build
        # itself substitutes for a dependency it did not find.
        + ''
          sed -i -E 's#r"@[A-Z0-9_]+_(INCDIR|INCLUDEDIR|LIBDIR|PCFILEDIR)@"#r"unknown"#g' scipy/__config__.py.in
          ! grep -qE 'r"@[A-Z0-9_]+_(INCDIR|INCLUDEDIR|LIBDIR|PCFILEDIR)@"' scipy/__config__.py.in
        ''
        # The interpreter is reported the same way. The upstream cross backport
        # above names the host one, a real runtime dependency worth keeping, but a
        # rebase drops that patch and is left naming the build host's.
        + lib.optionalString isHistory ''
          sed -i -E "s|^conf_data\.set\('PYTHON_PATH', .*\)$|conf_data.set('PYTHON_PATH', 'unknown')|" scipy/meson.build
          grep -q "^conf_data.set('PYTHON_PATH', 'unknown')$" scipy/meson.build
        ''
        # The linker script hides everything but PyInit_*, and the probe that
        # guards it links through wasixcc, which takes the flag where wasm-ld does
        # not. 1.18 reaches the same code and drops it for us.
        + lib.optionalString (lib.versionOlder package.version "1.18") ''
          sed -i "s|^version_link_args = \['-Wl,--version-script=' + _linker_script\]|version_link_args = []|" meson.build
          grep -q "^version_link_args = \[\]" meson.build
        ''
        # cimport numpy resolves through sys.path, which carries the build host's
        # numpy because pythran propagates it, while the headers come from the
        # numpy below. Cythonising against the newer pxd emits accessors the older
        # headers do not declare (PyDataType_TYPEOBJ, _PyUFuncObject_GET_ITEM_DATA).
        # An --include-dir is searched before sys.path and leaves imports alone.
        + lib.optionalString isHistory ''
          sed -i "s|^cython_args = \['-3',|cython_args = ['-3', '--include-dir', '${historyNumpy}/${packages.sameProfile.python.sitePackages}',|" scipy/meson.build
          grep -q "'--include-dir', '${historyNumpy}/${packages.sameProfile.python.sitePackages}'" scipy/meson.build
        '';
      # Dataset fixtures require network access; the special tests require the
      # omitted extension. Named tests are multiprocessing cases.
      disabledTestPaths = [
        "scipy/datasets/tests/test_data.py"
        "scipy/special/tests/test_dd.py"
        "scipy/special/tests/test_round.py"
      ];
      disabledTests = [
        "test__workers_wrapper"
        "test_mapwrapper_parallel"
        "test_mixed_threads_processes"
        "test_multiprocess"
        "test_pool"
        "test_public_modules_importable_2"
      ];
      pytestFlags = [
        "--deselect=scipy/integrate/tests/test__quad_vec.py::TestQuadVec::test_quad_vec_pool"
        "--deselect=scipy/integrate/tests/test__quad_vec.py::TestQuadVec::test_quad_vec_pool_args[10-2]"
        "--deselect=scipy/integrate/tests/test__quad_vec.py::TestQuadVec::test_quad_vec_pool_args[10-extra_args1]"
        # FITPACK accepts the third derivative at a repeated knot on WASIX.
        "--deselect=scipy/interpolate/tests/test_fitpack.py::TestSplder::test_kink"
        # Reference LAPACK differs by 1.9e-5 in one complex64 QR element.
        "--deselect=scipy/linalg/tests/test_decomp.py::TestQR::test_smoke_economic[complex64]"
        # Numeric worker counts create multiprocessing pools, unsupported on WASIX.
        "--deselect=scipy/optimize/tests/test__differential_evolution.py::TestDifferentialEvolutionSolver::test_immediate_updating"
        "--deselect=scipy/optimize/tests/test__differential_evolution.py::TestDifferentialEvolutionSolver::test_parallel_processes"
        "--deselect=scipy/optimize/tests/test__differential_evolution.py::TestDifferentialEvolutionSolver::test_parallel_threads"
        "--deselect=scipy/optimize/tests/test__shgo.py::TestShgoArguments::test_19_parallelization"
        "--deselect=scipy/optimize/tests/test__numdiff.py::TestApproxDerivativesDense::test_scalar_vector"
        "--deselect=scipy/optimize/tests/test__numdiff.py::TestApproxDerivativesDense::test_workers_evaluations_and_nfev"
        "--deselect=scipy/optimize/tests/test__numdiff.py::TestApproxDerivativesDense::test_vector_vector"
        "--deselect=scipy/optimize/tests/test__numdiff.py::TestApproxDerivativeSparse::test_all"
        "--deselect=scipy/optimize/tests/test_differentiable_functions.py::TestScalarFunction::test_workers"
        "--deselect=scipy/optimize/tests/test_differentiable_functions.py::TestVectorialFunction::test_workers"
        "--deselect=scipy/optimize/tests/test_least_squares.py::TestDogbox::test_workers"
        "--deselect=scipy/optimize/tests/test_least_squares.py::TestTRF::test_workers"
        "--deselect=scipy/optimize/tests/test_least_squares.py::TestLM::test_workers"
        "--deselect=scipy/optimize/tests/test_linprog.py::TestLinprogSimplexNoPresolve::test_bounds_infeasible_2"
        "--deselect=scipy/optimize/tests/test_minpack.py::TestFSolve::test_concurrent_no_gradient"
        "--deselect=scipy/optimize/tests/test_minpack.py::TestFSolve::test_concurrent_with_gradient"
        "--deselect=scipy/optimize/tests/test_minpack.py::TestLeastSq::test_concurrent_no_gradient"
        "--deselect=scipy/optimize/tests/test_minpack.py::TestLeastSq::test_concurrent_with_gradient"
        "--deselect=scipy/optimize/tests/test_optimize.py::TestBrute::test_workers"
        "--deselect=scipy/optimize/tests/test_optimize.py::TestWorkers"
        "--deselect=scipy/optimize/tests/test_optimize.py::test_multiprocessing_too_many_open_files_23080"
        # Reference LAPACK's float32 TFQMR misses convergence on this case.
        "--deselect=scipy/sparse/linalg/_isolve/tests/test_iterative.py::test_convergence[rand-sym-pd-F-tfqmr-numpy-batch_b0-batch_A0]"
        "--deselect=scipy/sparse/linalg/_isolve/tests/test_iterative.py::test_precond_dummy[rand-sym-pd-F-tfqmr-numpy-batch_b0-batch_A0]"
        # WASIX math paths do not raise these floating-point warnings.
        "--deselect=scipy/sparse/tests/test_array_api.py::test_sparse_dense_divide"
        "--deselect=scipy/special/tests/test_sf_error.py::test_check_overflow_message"
        "--deselect=scipy/stats/tests/test_fit.py::test_fit_error"
        # Multivariate-normal QMC returns NaNs for degenerate covariance.
        "--deselect=scipy/stats/tests/test_qmc.py::TestMultivariateNormalQMC::test_validations"
        "--deselect=scipy/stats/tests/test_qmc.py::TestMultivariateNormalQMC::test_MultivariateNormalQMCDegenerate"
        # These also assert floating-point warnings or exceptions.
        "--deselect=scipy/stats/tests/test_stats.py::TestKSTwoSamples::test_some_code_paths"
        "--deselect=scipy/stats/tests/test_stats.py::TestWassersteinDistance::test_inf_values"
        "--deselect=scipy/stats/tests/test_stats.py::TestEnergyDistance::test_inf_values"
        "--deselect=scipy/stats/tests/test_stats.py::TestBrunnerMunzel::test_brunnermunzel_normal_dist[numpy]"
      ];
    }
)
