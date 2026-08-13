# scipy for wasix. openblas throws "unsupported system: wasm32-wasi" at eval, so
# the provider becomes the flang-built reference LAPACK. 1.18 builds no Fortran
# of its own (_without-fortran=true costs only scipy.odr); an older release does,
# through wasixflang, which compiles with flang and links through wasixcc.
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
      ]
      ++ (
        if lib.versionAtLeast pyprev.scipy.version "1.18"
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
    postPatch =
      ''
        sed -i "/^py3.extension_module('_test_internal',$/,/^)$/d" scipy/special/meson.build
      ''
      # The linker script hides everything but PyInit_*, and the probe that
      # guards it links through wasixcc, which takes the flag where wasm-ld does
      # not. 1.18 reaches the same code and drops it for us.
      + lib.optionalString (lib.versionOlder pyprev.scipy.version "1.18") ''
        sed -i "s|^version_link_args = \['-Wl,--version-script=' + _linker_script\]|version_link_args = []|" meson.build
        grep -q "^version_link_args = \[\]" meson.build
      '';
  }
  (pyprev.scipy.override {
    blas = lapack;
    lapack = lapack;
    pythran = buildPythran;
    boost191 = buildBoost;
  })
