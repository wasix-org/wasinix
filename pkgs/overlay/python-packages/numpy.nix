# numpy for wasix. openblas throws "unsupported system: wasm32-wasi" at eval, so
# build against the bundled reference BLAS (-Dallow-noblas).
{
  pyprev,
  lib,
  helpers,
  ...
}:
# crossInclude names a path inside numpy's own output, so the definition is a fixpoint.
lib.fix (
  self:
    helpers.libTweaks (
      helpers.linkInputs (helpers.dropInputsByNameInfix ["blas" "lapack"])
      // {
        # What wasm C extensions must compile against: the build python's numpy
        # headers set NPY_SIZEOF_LONG=8, which mis-sizes npy_intp on wasm32.
        passthru.crossInclude = "${self}/lib/${pyprev.python.libPrefix}/site-packages/numpy/_core/include";
        # numpy < 2.3 vendors meson 1.5, which rejects default_both_libraries.
        mesonFlags = old:
          lib.filter (
            f:
              lib.versionAtLeast pyprev.numpy.version "2.3"
              || f != "-Ddefault_both_libraries=static"
          ) (old ++ [(lib.mesonBool "allow-noblas" true)]);
        # Replaces upstream's preBuild: its site.cfg symlink has dead BLAS paths.
        preBuild = _: "";
        # The long-double format is normally a run-probe; wasm32 is IEEE binary128.
        postPatch = _: (''
            substituteInPlace numpy/meson.build \
              --replace-fail 'py.full_path()' "'python'"

            substituteInPlace numpy/_core/meson.build \
              --replace-fail "meson.get_external_property('longdouble_format', 'UNKNOWN')" "meson.get_external_property('longdouble_format', 'IEEE_QUAD_LE')"
          ''
          # npy_cpu.h before 2.4 recognises wasm only under __EMSCRIPTEN__.
          + lib.optionalString (lib.versionOlder pyprev.numpy.version "2.4") ''
            substituteInPlace numpy/_core/include/numpy/npy_cpu.h \
              --replace-fail '#elif defined(__EMSCRIPTEN__)' '#elif defined(__EMSCRIPTEN__) || defined(__wasm__)'
          '');
      }
    )
    pyprev.numpy
)
