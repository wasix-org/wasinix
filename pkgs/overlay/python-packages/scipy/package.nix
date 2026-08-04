# scipy for wasix. openblas throws "unsupported system: wasm32-wasi" at eval, so
# the provider becomes the flang-built reference LAPACK; flang is not a wasix link
# driver, and _without-fortran=true costs only scipy.odr.
{
  pyprev,
  final,
  wasixPython,
  helpers,
  ...
}: let
  lapack = final.lapack-reference;
  # The cross pythran does not eval (reads hostPlatform.extensions.sharedLibrary).
  buildPythran = wasixPython.pythonOnBuildForHost.pkgs.pythran;
  # Boost.Build rejects architecture=wasm; boost.math is header-only anyway.
  buildBoost = final.buildPackages.boost191;
in
  helpers.libTweaks {
    mesonFlags = old:
      helpers.dropFlagsByPrefix ["-Dblas=" "-Dlapack="] old
      ++ [
        "-Dblas=blas"
        "-Dlapack=lapack"
        "-D_without-fortran=true"
      ];

    # dependency('boost')'s system method errors unless both dirs are set.
    env.BOOST_INCLUDEDIR = "${buildBoost.dev}/include";
    env.BOOST_LIBRARYDIR = "${buildBoost}/lib";

    # scipy's callers omit the hidden CHARACTER-length args flang emits, which
    # traps under wasm's strictly-typed call_indirect; the patches append them.
    patches = [
      ../patches/scipy-cython-blas-fortran-charlen.patch
      ../patches/scipy-hand-c-blas-fortran-charlen.patch
    ];

    # _test_internal calls fesetround(FE_UPWARD); wasm has no dynamic rounding
    # modes, so wasix-libc omits those fenv.h macros.
    postPatch = ''
      sed -i "/^py3.extension_module('_test_internal',$/,/^)$/d" scipy/special/meson.build
    '';
  }
  (pyprev.scipy.override {
    blas = lapack;
    lapack = lapack;
    pythran = buildPythran;
    boost191 = buildBoost;
  })
