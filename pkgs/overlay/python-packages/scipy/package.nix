# scipy for wasix. openblas throws "unsupported system: wasm32-wasi" at eval, so
# the provider becomes the flang-built reference LAPACK. 1.18 builds no Fortran
# of its own (_without-fortran=true costs only scipy.odr); an older release does,
# through wasixflang, which compiles with flang and links through wasixcc.
{
  pyprev,
  pyfinal,
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
  isHistory = (pyprev.scipy.passthru.wasix.historySpec or null) != null;
  # A release caps numpy a minor or two past itself, and the set's numpy is
  # beyond both caps, so a rebase takes the newest history entry under its own.
  # The one argument feeds both the meson include dir and the propagated
  # dependency, so the wheel compiles against the release it then declares.
  historyNumpy =
    if lib.versionOlder pyprev.scipy.version "1.15"
    then pyfinal.numpy_2_2_6
    else pyfinal.numpy_2_3_5;
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
    # nixpkgs carries an upstream cross-compilation backport cut against the
    # current release, whose hunks miss on an older src; ours are the port's own.
    patches = old:
      lib.optionals (!isHistory) old
      ++ [
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
      + lib.optionalString (lib.versionOlder pyprev.scipy.version "1.18") ''
        sed -i "s|^version_link_args = \['-Wl,--version-script=' + _linker_script\]|version_link_args = []|" meson.build
        grep -q "^version_link_args = \[\]" meson.build
      ''
      # cimport numpy resolves through sys.path, which carries the build host's
      # numpy because pythran propagates it, while the headers come from the
      # numpy below. Cythonising against the newer pxd emits accessors the older
      # headers do not declare (PyDataType_TYPEOBJ, _PyUFuncObject_GET_ITEM_DATA).
      # An --include-dir is searched before sys.path and leaves imports alone.
      + lib.optionalString isHistory ''
        sed -i "s|^cython_args = \['-3',|cython_args = ['-3', '--include-dir', '${historyNumpy}/${pyprev.python.sitePackages}',|" scipy/meson.build
        grep -q "'--include-dir', '${historyNumpy}/${pyprev.python.sitePackages}'" scipy/meson.build
      '';
  }
  (pyprev.scipy.override ({
      blas = lapack;
      lapack = lapack;
      pythran = buildPythran;
      boost191 = buildBoost;
    }
    // lib.optionalAttrs isHistory {numpy = historyNumpy;}))
