# scipy for wasix. openblas throws "unsupported system: wasm32-wasi" at eval, so
# the provider becomes the flang-built reference LAPACK; flang is not a wasix link
# driver, and _without-fortran=true costs only scipy.odr.
{
  pyprev,
  final,
  wasixPython,
  helpers,
  lib,
  ...
}: let
  lapack = final.lapack-reference;
  # The cross pythran does not eval (reads hostPlatform.extensions.sharedLibrary).
  buildPythran = wasixPython.pythonOnBuildForHost.pkgs.pythran;
  # Boost.Build rejects architecture=wasm; boost.math is header-only anyway.
  buildBoost = final.buildPackages.boost191;
in
  helpers.libTweaks {
    # 1.16 added the use-system-libraries option, so an older release aborts on
    # the flag; the vendored copies it then falls back to are what it shipped.
    mesonFlags = old:
      helpers.dropFlagsByPrefix (
        ["-Dblas=" "-Dlapack="]
        ++ lib.optional (lib.versionOlder pyprev.scipy.version "1.16") "-Duse-system-libraries="
      )
      old
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
    # 1.18 moved the generator's wrapper code, so an older release takes the
    # variant cut against the layout it still has.
    patches = [
      (
        if lib.versionOlder pyprev.scipy.version "1.18"
        then ../patches/scipy-cython-blas-fortran-charlen-pre118.patch
        else ../patches/scipy-cython-blas-fortran-charlen.patch
      )
      (
        if lib.versionOlder pyprev.scipy.version "1.18"
        then ../patches/scipy-hand-c-blas-fortran-charlen-pre118.patch
        else ../patches/scipy-hand-c-blas-fortran-charlen.patch
      )
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
